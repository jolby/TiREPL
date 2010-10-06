/**
 * Your Copyright Here
 *
 * Appcelerator Titanium is Copyright (c) 2009-2010 by Appcelerator, Inc.
 * and licensed under the Apache Public License (version 2)
 */
#import "TiModule.h"

@interface ComEvocomputingReplserverModule : TiModule 
{
  NSString *exampleProp;
}

-(id)createReplServer:(id)args;

@property(nonatomic, copy) NSString* exampleProp;

@end
