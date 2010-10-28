//
//  HTNotifier.m
//  HoptoadNotifier
//
//  Created by Caleb Davenport on 10/2/10.
//  Copyright 2010 GUI Cocoa, LLC. All rights reserved.
//

#import "HTNotifier.h"
#import "HTUtilities.h"
#import "HTNotice.h"

#define NTNotifierURL [NSString stringWithFormat:@"%@://%@%/notifier_api/v2/notices", \
(self.useSSL) ? @"https" : @"http", \
HTNotifierHostName]

// internal variables
static NSString * const HTNotifierAlwaysSendKey = @"AlwaysSendCrashReports";
static NSString * const HTNotifierFolderName = @"Hoptoad Notices";
static NSString * const HTNotifierPathExtension = @"notice";
static NSString * const HTNotifierHostName = @"hoptoadapp.com";
static HTNotifier * sharedNotifier = nil;

// extern strings
NSString * const HTNotifierVersion = @"1.1";
NSString * const HTNotifierBundleName = @"${BUNDLE}";
NSString * const HTNotifierBuildDate = @"${DATE}";
NSString * const HTNotifierBundleVersion  = @"${VERSION}";

#pragma mark -
#pragma mark c function prototypes
static NSString * HTLocalizedString(NSString *key);
static NSString * HTLogStringWithFormat(NSString *fmt, ...);
static NSString * HTLogStringWithArguments(NSString *fmt, va_list args);
static void HTLog(NSString *fmt, ...);
static void HTHandleException(NSException *);
static void HTHandleSignal(int signal);

#pragma mark -
#pragma mark private methods
@interface HTNotifier (private)
- (id)initWithAPIKey:(NSString *)key environmentName:(NSString *)name;
- (void)startHandler;
- (void)stopHandler;
- (void)handleException:(NSException *)e;
- (void)applicationDidBecomeActive:(NSNotification *)notif;
- (void)checkForNoticesAndReportIfReachable;
- (void)showNoticeAlert;
- (void)postAllNoticesWithAutoreleasePool;
- (void)postNoticesWithPaths:(NSArray *)paths;
- (BOOL)isHoptoadReachable;
- (NSString *)noticesDirectory;
- (NSArray *)noticePaths;
- (NSString *)noticePathWithName:(NSString *)name;
@end
@implementation HTNotifier (private)
- (id)initWithAPIKey:(NSString *)key environmentName:(NSString *)name {
	if (self = [super init]) {
		
		// log start statement
		HTLog(@"version %@", HTNotifierVersion);
		
		// create folder
		NSString *directory = [self noticesDirectory];
		if (![[NSFileManager defaultManager] fileExistsAtPath:directory]) {
			[[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
		}
		
		// setup values
		apiKey = [key copy];
		environmentName = [name copy];
		self.useSSL = NO;
		
		// register defaults
		[[NSUserDefaults standardUserDefaults] registerDefaults:
		 [NSDictionary dictionaryWithObject:@"NO" forKey:HTNotifierAlwaysSendKey]];
		
		// application notifications
		[self performSelectorOnMainThread:@selector(registerNotifications) withObject:nil waitUntilDone:YES];
		
		// start reachability
		reachability = SCNetworkReachabilityCreateWithName(NULL, [HTNotifierHostName UTF8String]);
		
		// start handler
		[self startHandler];
		
	}
	return self;
}
- (void)startHandler {
	NSSetUncaughtExceptionHandler(HTHandleException);
	for (NSNumber *signalValue in [[HTUtilities signals] allKeys]) {
		signal([signalValue intValue], HTHandleSignal);
	}
}
- (void)stopHandler {
	NSSetUncaughtExceptionHandler(NULL);
	for (NSNumber *signalValue in [[HTUtilities signals] allKeys]) {
		signal([signalValue intValue], SIG_DFL);
	}
}
- (void)handleException:(NSException *)e {
	[self stopHandler];

	// log crash
	NSString *noticeName = [NSString stringWithFormat:@"%d", time(NULL)];
	NSString *noticePath = [self noticePathWithName:noticeName];
	HTNotice *notice = [HTNotice noticeWithException:e];
	[notice writeToFile:noticePath];
	
	if ([self.delegate respondsToSelector:@selector(notifierDidHandleCrash)]) {
		[self.delegate notifierDidHandleCrash];
	}
}
- (void)applicationDidBecomeActive:(NSNotification *)notif {
	[self performSelectorInBackground:@selector(checkForNoticesAndReportIfReachable) withObject:nil];
}
- (void)checkForNoticesAndReportIfReachable {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	
	if ([self isHoptoadReachable]) {
		[self performSelectorOnMainThread:@selector(unregisterNotifications) withObject:nil waitUntilDone:YES];
		
		NSArray *notices = [self noticePaths];
		if ([notices count] > 0) {
			if ([[NSUserDefaults standardUserDefaults] boolForKey:HTNotifierAlwaysSendKey]) {
				[self postNoticesWithPaths:notices];
			}
			else {
				[self performSelectorOnMainThread:@selector(showNoticeAlert) withObject:nil waitUntilDone:YES];
			}
		}
	}
	
	[pool drain];
}
- (void)showNoticeAlert {
	if ([self.delegate respondsToSelector:@selector(notifierWillDisplayAlert)]) {
		[self.delegate notifierWillDisplayAlert];
	}
	
	NSString *bundleName = [HTUtilities bundleDisplayName];
	
	NSString *title = HTLocalizedString(@"NOTICE_TITLE");
	if ([self.delegate respondsToSelector:@selector(titleForNoticeAlert)]) {
		NSString *tempString = [self.delegate titleForNoticeAlert];
		if (tempString != nil) {
			title = tempString;
		}
	}
	title = [title stringByReplacingOccurrencesOfString:HTNotifierBundleName withString:bundleName];
	
	NSString *body = HTLocalizedString(@"NOTICE_BODY");
	if ([self.delegate respondsToSelector:@selector(bodyForNoticeAlert)]) {
		NSString *tempString = [self.delegate bodyForNoticeAlert];
		if (tempString != nil) {
			body = tempString;
		}
	}
	body = [body stringByReplacingOccurrencesOfString:HTNotifierBundleName withString:bundleName];
	
	UIAlertView *alert = [[UIAlertView alloc] initWithTitle:title
													message:body
												   delegate:self
										  cancelButtonTitle:HTLocalizedString(@"NO")
										  otherButtonTitles:HTLocalizedString(@"YES"), nil];
	[alert show];
	[alert release];
}
- (void)postAllNoticesWithAutoreleasePool {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	
	NSArray *paths = [self noticePaths];
	[self postNoticesWithPaths:paths];
	
	[pool drain];
}
- (void)postNoticesWithPaths:(NSArray *)paths {
	// setup post resources
	NSURL *url = [NSURL URLWithString:NTNotifierURL];
	
	// report each notice
	for (NSString *noticePath in paths) {
		
		// get notice payload
		HTNotice *notice = [HTNotice readFromFile:noticePath];
		NSData *xmlData = [notice hoptoadXMLData];
		
		// create url request
		NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:url
																	cachePolicy:NSURLCacheStorageNotAllowed
																timeoutInterval:10.0];
		[request setValue:@"text/xml" forHTTPHeaderField:@"Content-Type"];
		[request setHTTPMethod:@"POST"];
		[request setHTTPBody:xmlData];
		
		// create connection
		NSHTTPURLResponse *response = nil;
		NSError *error = nil;
		[NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
		[request release];
		NSInteger statusCode = [response statusCode];
		
		// error
		if (error != nil) {
			HTLog(@"encountered error while posting notice\n%@", error);
		}
		
		// status code
		if (statusCode == 200) {
			HTLog(@"crash report posted");
		}
		else if (statusCode == 403) {
			HTLog(@"the requested project does not support SSL");
		}
		else if (statusCode == 422) {
			HTLog(@"your api key is not correct");
		}
		else {
			HTLog(@"unexpected errors (%d) - submit a bug report at http://help.hoptoadapp.com", statusCode);
		}
		
		// delete report
		[[NSFileManager defaultManager] removeItemAtPath:noticePath error:nil];
	}
}
- (BOOL)isHoptoadReachable {
	SCNetworkReachabilityFlags flags;
	SCNetworkReachabilityGetFlags(reachability, &flags);
	return ((flags & kSCNetworkReachabilityFlagsReachable) != 0);
}
- (NSString *)noticesDirectory {
	NSString *path = nil;
	NSArray *folders = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
	if ([folders count] == 0) {
		path = [NSTemporaryDirectory() stringByAppendingPathComponent:HTNotifierFolderName];
	}
	else {
		NSString *library = [folders lastObject];
		path = [library stringByAppendingPathComponent:HTNotifierFolderName];
	}
	return path;
}
- (NSArray *)noticePaths {
	NSString *directory = [self noticesDirectory];
	NSArray *directoryContents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:nil];
	NSMutableArray *crashes = [NSMutableArray arrayWithCapacity:[directoryContents count]];
	for (NSString *file in directoryContents) {
		if ([[file pathExtension] isEqualToString:HTNotifierPathExtension]) {
			NSString *crashPath = [directory stringByAppendingPathComponent:file];
			[crashes addObject:crashPath];
		}
	}
	return crashes;
}
- (NSString *)noticePathWithName:(NSString *)name {
	NSString *path = [[self noticesDirectory] stringByAppendingPathComponent:name];
	if ([[path pathExtension] length] == 0) {
		path = [path stringByAppendingPathExtension:HTNotifierPathExtension];
	}
	return path;
}
- (void)registerNotifications {
	[[NSNotificationCenter defaultCenter] addObserver:self
											 selector:@selector(applicationDidBecomeActive:)
												 name:UIApplicationDidBecomeActiveNotification
											   object:nil];
}
- (void)unregisterNotifications {
	[[NSNotificationCenter defaultCenter] removeObserver:self
													name:UIApplicationDidBecomeActiveNotification
												  object:nil];
}
@end

#pragma mark -
#pragma mark public implementation
@implementation HTNotifier

@synthesize apiKey;
@synthesize environmentName;
@synthesize useSSL;
@synthesize environmentInfo;
@synthesize delegate;
@synthesize logCrashesInSimulator;

+ (void)startNotifierWithAPIKey:(NSString *)key environmentName:(NSString *)name {
	@synchronized(self) {
		if (sharedNotifier == nil) {
			
			if (key == nil || [key length] == 0) {
				[NSException raise:NSInvalidArgumentException
							format:@"", HTLogStringWithFormat(@"The provided API key is not valid")];
			}
			
			if (name == nil || [name length] == 0) {
				[NSException raise:NSInvalidArgumentException
							format:@"", HTLogStringWithFormat(@"The provided environment name is not valid")];
			}
			
			sharedNotifier = [[self alloc] initWithAPIKey:key environmentName:name];
		}
	}
}
+ (HTNotifier *)sharedNotifier {
	@synchronized(self) {
		return sharedNotifier;
	}
}
+ (id)allocWithZone:(NSZone *)zone {
	@synchronized(self) {
		if(sharedNotifier == nil) {
			sharedNotifier = [super allocWithZone:zone];
			return sharedNotifier;
		}
	}
	return nil;
}
- (id)copyWithZone:(NSZone *)zone {
	return self;
}
- (id)retain {
	return self;
}
- (NSUInteger)retainCount {
	return NSUIntegerMax;
}
- (void)release {
	// do nothing
}
- (id)autorelease {
	return self;
}
- (void)dealloc {
	[self stopHandler];
	
	[self performSelectorOnMainThread:@selector(unregisterNotifications) withObject:nil waitUntilDone:YES];
	
	if (reachability != NULL) { CFRelease(reachability), reachability = NULL; }
	[apiKey release], apiKey = nil;
	[environmentName release], environmentName = nil;
	self.environmentInfo = nil;
	
	[super dealloc];
}
- (void)writeTestNotice {
	NSString *noticePath = [self noticePathWithName:@"TEST"];
	
	if ([[NSFileManager defaultManager] fileExistsAtPath:noticePath]) {
		return;
	}
	
	HTNotice *notice = [HTNotice testNotice];
	[notice writeToFile:noticePath];
}
- (void)alertView:(UIAlertView *)alertView didDismissWithButtonIndex:(NSInteger)buttonIndex {
	if (buttonIndex == alertView.cancelButtonIndex ||
		[[alertView title] isEqualToString:HTLocalizedString(@"THANKS")]) {
		if ([self.delegate respondsToSelector:@selector(notifierDidDismissAlert)]) {
			[self.delegate notifierDidDismissAlert];
		}
	}
}
- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
	NSString *title = [alertView title];
	
	if ([title isEqualToString:HTLocalizedString(@"THANKS")]) {
		if (buttonIndex != alertView.cancelButtonIndex) {
			[[NSUserDefaults standardUserDefaults] setBool:YES forKey:HTNotifierAlwaysSendKey];
			[[NSUserDefaults standardUserDefaults] synchronize];
		}
	}
	else {
		if (buttonIndex == alertView.cancelButtonIndex) {
			NSArray *noticePaths = [self noticePaths];
			for (NSString *notice in noticePaths) {
				[[NSFileManager defaultManager] removeItemAtPath:notice
														   error:nil];
			}
		}
		else {
			[self performSelectorInBackground:@selector(postAllNoticesWithAutoreleasePool) withObject:nil];
			UIAlertView *alert = [[UIAlertView alloc] initWithTitle:HTLocalizedString(@"THANKS")
															message:HTLocalizedString(@"AUTOMATICALLY_SEND_QUESTION")
														   delegate:self
												  cancelButtonTitle:HTLocalizedString(@"NO")
												  otherButtonTitles:HTLocalizedString(@"YES"), nil];
			[alert show];
			[alert release];
		}
	}
}

@end

#pragma mark -
#pragma mark c function implementations
static NSString * HTLocalizedString(NSString *key) {
	return NSLocalizedStringFromTable(key, @"HTNotifier", @"");
}
static void HTHandleException(NSException *e) {
	[sharedNotifier performSelectorOnMainThread:@selector(handleException:) withObject:e waitUntilDone:YES];
}
static void HTHandleSignal(int signal) {
	NSNumber *signalNumber = [NSNumber numberWithInteger:signal];
	NSString *signalName = [[HTUtilities signals] objectForKey:signalNumber];
	[NSException raise:@"HTSignalRaisedException"
				format:@"Application received signal %@", signalName];
}
static void HTLog(NSString *frmt, ...) {
	va_list list;
	va_start(list, frmt);
	NSLog(@"%@", HTLogStringWithArguments(frmt, list));
	va_end(list);
}
static NSString *HTLogStringWithFormat(NSString *fmt, ...) {
	va_list list;
	va_start(list, fmt);
	NSString *toReturn = HTLogStringWithArguments(fmt, list);
	va_end(list);
	return toReturn;
}
static NSString *HTLogStringWithArguments(NSString *fmt, va_list args) {
	NSString *format = [[NSString alloc] initWithFormat:fmt arguments:args];
	NSString *toReturn = [@"[HoptoadNotifier]" stringByAppendingString:format];
	[format release];
	return toReturn;
}