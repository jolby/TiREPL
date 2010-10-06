#import "ComEvocomputingReplserverProxy.h" 

#import "AsyncSocket.h"
#import "Base64Transcoder.h"
#import "SBJSON.h"
#import "TiBase.h"
#import "TiUtils.h"
#import "TiApp.h"
#import "KrollBridge.h"


enum MessageTags
{
  WelcomeMsg = 0,
  GenericMsg,
  WarningMsg,
};


void PrintCurrentThread()
{
  NSLog(@"Current thread: %@",[[NSThread currentThread] name]);
}


//XXX--place in NSString/NSData extra category
NSString* ec_encode64(NSString *str)
{
  const char *data = [str UTF8String];
  size_t len = [str length];
  
  size_t outsize = EstimateBas64EncodedDataSize(len);
  char *base64Result = malloc(sizeof(char)*outsize);
  size_t theResultLength = outsize;
    
  bool result = Base64EncodeData(data, len, base64Result, &theResultLength);
  if (result) {
      NSData *theData = [NSData dataWithBytes:base64Result length:theResultLength];
      free(base64Result);
      //blech
      NSString *strWithNewlines = [[NSString alloc] initWithData:theData
                                                        encoding:NSASCIIStringEncoding];
      NSString *retval = [strWithNewlines stringByReplacingOccurrencesOfString:@"\r\n" withString:@""];
      [strWithNewlines release];
      return retval;
  }
  free(base64Result);
  return nil;
}


NSString* ec_decode64(NSString *str)
{
  const char *data = [str UTF8String];
  size_t len = [str length];
  
  size_t outsize = EstimateBas64DecodedDataSize(len);
  char *base64Result = malloc(sizeof(char)*outsize);
  size_t theResultLength = outsize;
  
  bool result = Base64DecodeData(data, len, base64Result, &theResultLength);
  if (result) {
    NSData *theData = [NSData dataWithBytes:base64Result length:theResultLength];
    free(base64Result);
    return [[[NSString alloc] initWithData:theData
                                  encoding:NSASCIIStringEncoding] autorelease];
  }
  free(base64Result);
  return nil;
}


@implementation KrollEvalWithCallback

-(id)initWithCode:(NSString*)code_ callbackTarget:(id)callbackTarget_ successMethod:(SEL)successMethod_
  errorbackTarget:(id)errorbackTarget_ errorMethod:(SEL)errorMethod_
{
  if (self = [super init]) {
    message = nil;
    code = [code_ copy];    
    callbackTarget = [callbackTarget_ retain];
    errorbackTarget = [errorbackTarget_ retain];
    successMethod = successMethod_;
    errorMethod = errorMethod_;
  }
  return self;
}

-(id)initWithMessage:(NSDictionary*)message_ callbackTarget:(id)callbackTarget_ successMethod:(SEL)successMethod_ 
  errorbackTarget:(id)errorbackTarget_ errorMethod:(SEL)errorMethod_
{
  if (self = [super init]) {
    message = [message_ retain];
    code = [[message objectForKey:@"src"] copy];
    callbackTarget = [callbackTarget_ retain];
    errorbackTarget = [errorbackTarget_ retain];
    successMethod = successMethod_;
    errorMethod = errorMethod_;
  }
  return self;
}

-(void)dealloc
{
  [message release];
  [code release];
  [callbackTarget release];
  [errorbackTarget release];
  [super dealloc];
}

-(void)invoke:(KrollContext*)context
{
  //PrintCurrentThread();
  TiStringRef js = TiStringCreateWithUTF8CString([code UTF8String]); 
  TiObjectRef global = TiContextGetGlobalObject([context context]);
  //XXX--lifecycle for these two below???
  TiValueRef exception = NULL;
  TiValueRef result = TiEvalScript([context context], js, global, NULL, 1, &exception);
  
  if (exception!=NULL) {
    id excm = [KrollObject toID:context value:exception];

    if(message == nil) {      
      NSLog(@"[ERROR] INVOKE Script Error = %@",[TiUtils exceptionMessage:excm]);
      fflush(stderr);      
      [errorbackTarget performSelector:errorMethod withObject:excm];
    } 
    else {
      NSDictionary *returnMsg = [NSDictionary dictionaryWithObjectsAndKeys: [message objectForKey:@"session-id"], @"session-id",
                                                     [message objectForKey:@"id"], @"id",
                                              @"error", @"status",
                                                      [TiUtils stringValue:excm], @"result",
                                              nil];
      [callbackTarget performSelector:errorMethod withObject:returnMsg];
    }    
    
  } else {
    id resval = [KrollObject toID:context value:result];
    if(message == nil) {

      NSLog(@"[DEBUG] INVOKE Script Result = %@",[TiUtils stringValue:resval]);
      [callbackTarget performSelector:successMethod withObject:resval];
    }
    else {
      NSDictionary *returnMsg = [NSDictionary dictionaryWithObjectsAndKeys:
                                                     [message objectForKey:@"session-id"], @"session-id",
                                                     [message objectForKey:@"id"], @"id",
                                              @"ok", @"status",
                                                      [TiUtils stringValue:[TiUtils stringValue:resval]], @"result",
                                              nil];
      [callbackTarget performSelector:successMethod withObject:returnMsg];
    }
  }
  TiStringRelease(js);
}
@end


@implementation ReplserverSession

@synthesize sessionSocket, uuid;

-(id)initWithSocket:(AsyncSocket*)socket_ andServer:(ComEvocomputingReplserverProxy*)server_
{
  self = [super init];

  if (self != nil) {
    sessionSocket = [socket_ retain];
    [sessionSocket setDelegate:self];
    server = server_;
    uuid = [[TiUtils createUUID] copy];
  }
  
  NSLog(@"[DEBUG] ReplserverSession init: %@...",self);
  return self;
}

-(void)dealloc
{
  NSLog(@"[DEBUG] ReplserverSession dealloc...");
  [sessionSocket setDelegate:nil];
  [sessionSocket disconnect];
  [sessionSocket release];
  [uuid release];
  [super dealloc];
}

-(void)printAndRead:(NSString*)output
{
  NSLog(@"[DEBUG] printAndRead: %@",output);
  [sessionSocket writeData:[output dataUsingEncoding:NSUTF8StringEncoding] withTimeout:-1 tag:GenericMsg];
  [sessionSocket writeData:[@"\nREPL> " dataUsingEncoding:NSUTF8StringEncoding] withTimeout:-1 tag:GenericMsg];
  [sessionSocket readDataToData:[AsyncSocket LFData] withTimeout:-1 tag:GenericMsg];
}

-(void)onEvalSuccess:(id)result
{
  NSLog(@"[DEBUG] onEvalSuccess result = %@", [TiUtils stringValue:result]);
  [self performSelectorOnMainThread:@selector(printAndRead:) withObject:[TiUtils stringValue:result]  waitUntilDone:NO];
}

-(void)onEvalMessageSuccess:(id)result
{
  NSLog(@"[DEBUG] onEvalMessageSuccess result = %@", [TiUtils stringValue:result]);
  
  NSString *jsonStr = [SBJSON stringify:result];
  NSString *b64Str = ec_encode64(jsonStr);
  NSString *returnMsg = [NSString stringWithFormat:@"/message_response %@", b64Str];
  [self performSelectorOnMainThread:@selector(printAndRead:) withObject:returnMsg  waitUntilDone:NO];
}

-(void)onEvalError:(id)error
{
  NSLog(@"[ERROR] onEvalError Script Error = %@",[TiUtils exceptionMessage:error]);
  [self performSelectorOnMainThread:@selector(printAndRead:) withObject:[TiUtils stringValue:error]  waitUntilDone:NO];
}

-(void)onEvalMessageError:(id)error
{
  NSString *jsonStr = [SBJSON stringify:error];
  NSString *b64Str = ec_encode64(jsonStr);
  NSString *returnMsg = [NSString stringWithFormat:@"/message_response %@", b64Str];
  [self performSelectorOnMainThread:@selector(printAndRead:) withObject:returnMsg  waitUntilDone:NO];
}

-(void)dispatchMessage:(NSString *)msgBody
{
  NSString *jsonStr = ec_decode64(msgBody);
  NSLog(@"%@",jsonStr);
  
  SBJSON *json = [[SBJSON alloc] init];	
  NSError *error = nil;
  NSDictionary *msgDict = [json fragmentWithString:jsonStr error:&error];
  [json release];

  if (error != nil) {
    NSLog(@"Got error from json: %@",error);
    [self printAndRead:[error description]];      
  } 
  else {
    NSLog(@"Got dict from json: %@",msgDict);      
    KrollBridge *krollBridge = [[TiApp app] krollBridge];    
    KrollContext *krollContext = [krollBridge krollContext];
    
    KrollEvalWithCallback *evalWithCB = [[[KrollEvalWithCallback alloc] 
                                               initWithMessage:msgDict
                                                callbackTarget:self successMethod:@selector(onEvalMessageSuccess:)
                                               errorbackTarget:self errorMethod:@selector(onEvalMessageError:)] autorelease];
    [krollContext enqueue:evalWithCB];  
  }  
}

#pragma mark AsyncSocket Delegate methods

- (void)onSocketDidDisconnect:(AsyncSocket *)socket
{
  NSLog(@"Disconnected");
  
  ReplserverSession *session = [server findSessionForSocket:socket];
  if(session) {
    [server removeClient:session];
  }
}

- (void)onSocket:(AsyncSocket *)socket willDisconnectWithError:(NSError *)err
{
  NSLog(@"Client Disconnected with error: %@, %@", socket, err);
}

- (void)onSocket:(AsyncSocket *)socket didConnectToHost:(NSString *)host port:(UInt16)port
{
  NSLog(@"Accepted client %@", socket);
  
  NSString *bundleName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"];
  NSString *welcomeMsg = [NSString stringWithFormat:@"Welcome to the %@ REPL Server\n", bundleName];
  [self printAndRead:welcomeMsg];
}

- (void)onSocket:(AsyncSocket *)socket didReadData:(NSData *)data withTag:(long)tag
{  
  NSString *input = [[NSString stringWithUTF8String:[data bytes]] 
                      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  
  NSLog(@"Got input from client:  %@", input);

  if ([input hasPrefix:@"/q"] || [input hasPrefix:@"/quit"]) {
    [socket writeData:[@"Bye!\n" dataUsingEncoding:NSUTF8StringEncoding] withTimeout:-1 tag:GenericMsg];
    [socket disconnectAfterWriting];
    return;
  }
  else if ([input hasPrefix:@"/session_id"]){
    NSLog(@"[DEBUG] uuid: %@", uuid);
    [self printAndRead:[NSString stringWithFormat:@"/session_id %@\n", uuid]];
    return;
  }
  else if ([input hasPrefix:@"/message "]) {
    NSString *msgBody = [input substringFromIndex:9];
    NSLog(@"%@", [NSString stringWithFormat:@"Got Message: %@", msgBody]);
    [self dispatchMessage:msgBody];
    return;
  }
  else {
    //raw eval
    NSLog(@"Raw eval: %@\n",input);
    KrollBridge *krollBridge = [[TiApp app] krollBridge];    
    KrollContext *krollContext = [krollBridge krollContext];
    
    KrollEvalWithCallback *evalWithCB = [[[KrollEvalWithCallback alloc] 
                                           initWithCode:input callbackTarget:self successMethod:@selector(onEvalSuccess:)
                                           errorbackTarget:self errorMethod:@selector(onEvalError:)] autorelease];
    [krollContext enqueue:evalWithCB];
    return;
  }
}

@end



@implementation ComEvocomputingReplserverProxy

@synthesize running, listenPort;

-(id)init
{
  self = [super init];
  
  if (self != nil) {
    listenSocket = [[AsyncSocket alloc] initWithDelegate:self];
    connectedClients = [[NSMutableArray alloc] initWithCapacity:1];
    self.listenPort = [NSNumber numberWithInt:5051];
    running = false;
  }
  
  return self;
}

-(void)dealloc
{
  [self stop:nil];
  [connectedClients release];
  [listenSocket release];
  [listenPort release];
  [super dealloc];
}

-(void)removeClient:(ReplserverSession*)session
{
  [connectedClients removeObject:session];  
}

-(id)findSessionForSocket:(AsyncSocket*)sock
{
  for (ReplserverSession* session in connectedClients) {
    if ([session sessionSocket] == sock)
      return session;
  }
  return nil;
}

#pragma mark Start/Stop server

-(void)startListening
{
  //XXX- this method needs to be run on the main thread
  NSInteger _listenPort = [self.listenPort intValue];
  
  if (_listenPort < 0 || _listenPort > 65535) {
    // Throw error instead??
    _listenPort = 0;
  }
    
  NSError *error = nil;
  [listenSocket setRunLoopModes:[NSArray arrayWithObject:NSRunLoopCommonModes]];
  if (![listenSocket acceptOnPort:_listenPort error:&error]) {
    NSLog(@"Error starting Debug Server: %@", error);
    return;
  }
  
  NSString *bundleName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"];
  NSLog(@"%@ Debug Server started on port %hu", bundleName, [listenSocket localPort]);    
  running = true;
}

-(void)start:(id)args
{
  if (running) {
    return;
  }

  NSString *bundleName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"];
  NSLog(@"%@ REPL Server starting...", bundleName);
  
  //took me a while to figure out I needed to run this on the main thread...duh
  [self performSelectorOnMainThread:@selector(startListening) withObject:nil waitUntilDone:YES];
}

-(void)stop:(id)args
{
  NSLog(@"Debug Server stopping...");
  if (!running) {
        return;
  }

  [listenSocket disconnect];  
  // Stop any client connections
  for (ReplserverSession* session in connectedClients) {
    // Will call onSocketDidDisconnect: in client which will remove it from connectedClients
    [[session sessionSocket] disconnect];
  }
  
  NSLog(@"Debug Server stopped");
  running = false;
}


-(BOOL)isRunning:(id)ignore
{
  return running;
}

-(NSString *)status:(id)ignore
{
  if(running) {
    return @"RUNNING";
  }
  return @"STOPPED";
}

#pragma mark AsyncSocket Delegate methods

- (void)onSocket:(AsyncSocket *)socket didAcceptNewSocket:(AsyncSocket *)newSocket
{
  NSLog(@"Connected. Socket: %@ didAcceptNewSocket: %@", socket, newSocket);
  ReplserverSession *session = [[ReplserverSession alloc] initWithSocket:newSocket andServer:self];
  [connectedClients addObject:session];  
  [session release];
}

- (void)onSocket:(AsyncSocket *)socket willDisconnectWithError:(NSError *)err
{
  NSLog(@"Listen socket Disconnected with error: %@, %@", socket, err);
}

- (void)onSocketDidDisconnect:(AsyncSocket *)socket
{
  NSLog(@"Socket Disconnected: %@",socket);
}

- (void)onSocket:(AsyncSocket *)socket didConnectToHost:(NSString *)host port:(UInt16)port;
{
  NSLog(@"Server Accepted client %@", socket);
}

@end
