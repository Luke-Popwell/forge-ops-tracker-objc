#import "FOTTestHTTPServer.h"
#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>

@implementation FOTTestHTTPServer {
    int _listenFD;
    volatile BOOL _running;
    NSMutableArray<NSDictionary<NSString *, id> *> *_requests;
    NSLock *_lock;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _requests = [NSMutableArray array];
        _lock = [[NSLock alloc] init];
        _listenFD = -1;
    }
    return self;
}

- (void)start {
    _listenFD = socket(AF_INET, SOCK_STREAM, 0);
    int reuse = 1;
    setsockopt(_listenFD, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0; // ask the OS for a free port

    bind(_listenFD, (struct sockaddr *)&addr, sizeof(addr));
    listen(_listenFD, 16);

    struct sockaddr_in bound;
    socklen_t boundLen = sizeof(bound);
    getsockname(_listenFD, (struct sockaddr *)&bound, &boundLen);
    _port = ntohs(bound.sin_port);

    _running = YES;
    NSThread *thread = [[NSThread alloc] initWithTarget:self selector:@selector(acceptLoop) object:nil];
    thread.qualityOfService = NSQualityOfServiceUtility;
    [thread start];
}

- (void)stop {
    _running = NO;
    if (_listenFD >= 0) {
        close(_listenFD);
        _listenFD = -1;
    }
}

- (NSArray<NSDictionary<NSString *, id> *> *)requests {
    [_lock lock];
    NSArray *copy = [_requests copy];
    [_lock unlock];
    return copy;
}

- (void)acceptLoop {
    while (_running) {
        fd_set readSet;
        FD_ZERO(&readSet);
        FD_SET(_listenFD, &readSet);
        struct timeval timeout = { .tv_sec = 0, .tv_usec = 100000 };

        int ready = select(_listenFD + 1, &readSet, NULL, NULL, &timeout);
        if (ready <= 0 || !_running) {
            continue;
        }

        int clientFD = accept(_listenFD, NULL, NULL);
        if (clientFD < 0) {
            continue;
        }
        [self handleClient:clientFD];
        close(clientFD);
    }
}

- (void)handleClient:(int)clientFD {
    NSMutableData *buffer = [NSMutableData data];
    char chunk[4096];
    NSRange headerEnd = NSMakeRange(NSNotFound, 0);

    // Read until the blank line ending the headers.
    while (headerEnd.location == NSNotFound) {
        ssize_t n = read(clientFD, chunk, sizeof(chunk));
        if (n <= 0) {
            return;
        }
        [buffer appendBytes:chunk length:n];
        headerEnd = [buffer rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]
                                 options:0
                                   range:NSMakeRange(0, buffer.length)];
    }

    NSString *headerText = [[NSString alloc] initWithData:[buffer subdataWithRange:NSMakeRange(0, headerEnd.location)]
                                                   encoding:NSUTF8StringEncoding];
    NSArray<NSString *> *lines = [headerText componentsSeparatedByString:@"\r\n"];
    NSArray<NSString *> *requestLine = [lines.firstObject componentsSeparatedByString:@" "];
    NSString *method = requestLine.count > 0 ? requestLine[0] : @"";
    NSString *path = requestLine.count > 1 ? requestLine[1] : @"";

    NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary dictionary];
    for (NSString *line in [lines subarrayWithRange:NSMakeRange(1, lines.count - 1)]) {
        NSRange colon = [line rangeOfString:@": "];
        if (colon.location != NSNotFound) {
            headers[[line substringToIndex:colon.location]] = [line substringFromIndex:colon.location + colon.length];
        }
    }

    NSUInteger contentLength = headers[@"Content-Length"] ? (NSUInteger)headers[@"Content-Length"].integerValue : 0;
    NSUInteger bodyStart = headerEnd.location + headerEnd.length;
    while (buffer.length - bodyStart < contentLength) {
        ssize_t n = read(clientFD, chunk, sizeof(chunk));
        if (n <= 0) {
            break;
        }
        [buffer appendBytes:chunk length:n];
    }
    NSData *bodyData = [buffer subdataWithRange:NSMakeRange(bodyStart, MIN(contentLength, buffer.length - bodyStart))];
    NSString *body = [[NSString alloc] initWithData:bodyData encoding:NSUTF8StringEncoding] ?: @"";

    [_lock lock];
    [_requests addObject:@{ @"method": method, @"path": path, @"headers": headers, @"body": body }];
    [_lock unlock];

    NSString *status = [path isEqualToString:@"/unauthorized"] ? @"401 Unauthorized" : @"202 Accepted";
    NSString *response = [NSString stringWithFormat:@"HTTP/1.1 %@\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", status];
    NSData *responseData = [response dataUsingEncoding:NSUTF8StringEncoding];
    write(clientFD, responseData.bytes, responseData.length);
}

@end
