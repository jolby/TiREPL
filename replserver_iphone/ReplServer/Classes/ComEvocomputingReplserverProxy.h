/**
 * Your Copyright Here
 *
 * Appcelerator Titanium is Copyright (c) 2009-2010 by Appcelerator, Inc.
 * and licensed under the Apache Public License (version 2)
 */
#import "TiProxy.h"

@class AsyncSocket;
@class ReplserverSession;
@class ComEvocomputingReplserverProxy;

@interface KrollEvalWithCallback : NSObject {
  NSString *code;
  NSDictionary *message; //can be null for raw code eval
  id callbackTarget;
  SEL successMethod;
  id errorbackTarget;
  SEL errorMethod;  
}

-(id)initWithCode:(NSString*)code callbackTarget:(id)callbackTarget successMethod:(SEL)successMethod 
  errorbackTarget:(id)errorbackTarget errorMethod:(SEL)errorMethod;

-(id)initWithMessage:(NSDictionary*)message callbackTarget:(id)callbackTarget successMethod:(SEL)successMethod 
  errorbackTarget:(id)errorbackTarget errorMethod:(SEL)errorMethod;

-(void)invoke:(KrollContext*)context;

@end

@interface ReplserverSession : NSObject {
  NSString *uuid;
  ComEvocomputingReplserverProxy *server;
  AsyncSocket *sessionSocket;
}

-(id)initWithSocket:(AsyncSocket*)socket_ andServer:(ComEvocomputingReplserverProxy*)server_;

@property(nonatomic, copy) NSString *uuid;
@property(nonatomic, readonly, retain) AsyncSocket *sessionSocket;

@end


@interface ComEvocomputingReplserverProxy : TiProxy
{
  AsyncSocket *listenSocket;
  NSNumber *listenPort;
  NSMutableArray *connectedClients;
  BOOL running;
}

-(void)start:(id)args;
-(void)stop:(id)args;
-(id)findSessionForSocket:(AsyncSocket*)sock;
-(void)removeClient:(ReplserverSession*)session;

-(BOOL)isRunning:(id)ignore;
-(NSString*)status:(id)ignore;

@property(nonatomic,readonly) BOOL running;
@property(nonatomic, retain) NSNumber *listenPort;

@end
