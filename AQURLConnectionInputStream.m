/*
 * AQURLConnectionInputStream.m
 * AQURLConnectionInputStream
 * 
 * Created by Jim Dovey on 31/08/2011.
 * 
 * Copyright (c) 2011 Jim Dovey
 * All rights reserved.
 * 
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 
 * Redistributions of source code must retain the above copyright notice,
 * this list of conditions and the following disclaimer.
 * 
 * Redistributions in binary form must reproduce the above copyright
 * notice, this list of conditions and the following disclaimer in the
 * documentation and/or other materials provided with the distribution.
 * 
 * Neither the name of the project's author nor the names of its
 * contributors may be used to endorse or promote products derived from
 * this software without specific prior written permission.
 * 
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
 * FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
 * TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
 * NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 */

#import "AQURLConnectionInputStream.h"

#if TARGET_OS_IPHONE
# import <CFNetwork/CFNetwork.h>
#else
# import <CoreServices/../Frameworks/CFNetwork.framework/Headers/CFNetwork.h>
#endif

NSString * const AQStreamPropertyURLRequest = @"AQStreamPropertyURLRequest";
NSString * const AQStreamPropertyURLResponse = @"AQStreamPropertyURLResponse";

@implementation AQURLConnectionInputStream

- (id) initWithURLRequest: (NSURLRequest *) request
{
	if ( request == nil )
	{
		[self release];
		return ( nil );
	}
	
	self = [super init];
	if ( self == nil )
		return ( nil );
	
	_request = [request copy];
	_connection = [[NSURLConnection alloc] initWithRequest: _request delegate: self startImmediately: NO];
	_properties = [NSMutableDictionary new];
	_buffer = [[NSMutableData alloc] initWithCapacity: 2048];
	
	return ( self );
}

- (void) dealloc
{
	if ( _streamStatus > NSStreamStatusNotOpen && _streamStatus < NSStreamStatusClosed )
		[self close];
	[_request release];
	[_response release];
	[_connection release];
	[_streamError release];
	[_properties release];
	[_buffer release];
	[_debugOutput release];
	[super dealloc];
}

- (CFHTTPMessageRef) copyCFRequestMessage
{
	if ( _request == nil )
		return ( NULL );		// no request ???
	if ( [[[_request URL] scheme] hasPrefix: @"http"] == NO )
		return ( NULL );		// not a HTTP request, so no CFHTTPMessage
	
	CFHTTPMessageRef result = CFHTTPMessageCreateRequest(kCFAllocatorDefault, (CFStringRef)[_request HTTPMethod], (CFURLRef)[[_request URL] absoluteURL], kCFHTTPVersion1_1);
	if ( result == NULL )
		return ( NULL );
	
	CFHTTPMessageSetBody(result, (CFDataRef)[_request HTTPBody]);
	[[_request allHTTPHeaderFields] enumerateKeysAndObjectsUsingBlock: ^(id key, id obj, BOOL *stop) {
		CFHTTPMessageSetHeaderFieldValue(result, (CFStringRef)key, (CFStringRef)obj);
	}];
	
	return ( result );
}

- (CFHTTPMessageRef) copyCFResponseMessage
{
	if ( _response == nil )
		return ( NULL );		// no response (yet)
	if ( [_response isKindOfClass: [NSHTTPURLResponse class]] == NO )
		return ( NULL );		// not a HTTP response, so no CFHTTPMessage
	
	CFHTTPMessageRef result = CFHTTPMessageCreateResponse(kCFAllocatorDefault, [_response statusCode], (CFStringRef)[NSHTTPURLResponse localizedStringForStatusCode: [_response statusCode]], kCFHTTPVersion1_1);
	if ( result == NULL )
		return ( NULL );
	
	[[_response allHeaderFields] enumerateKeysAndObjectsUsingBlock: ^(id key, id obj, BOOL *stop) {
		CFHTTPMessageSetHeaderFieldValue(result, (CFStringRef)key, (CFStringRef)obj);
	}];
	
	return ( result );
}

- (void) open
{
	if ( _streamStatus == NSStreamStatusNotOpen )
	{
		[_connection start];
		_streamStatus = NSStreamStatusOpening;
	}
}

- (void) close
{
	if ( _streamStatus > NSStreamStatusNotOpen && _streamStatus < NSStreamStatusAtEnd )
	{
		[_connection cancel];
		_streamStatus = NSStreamStatusClosed;
	}
}

- (NSStreamStatus) streamStatus
{
	return ( _streamStatus );
}

- (NSError *) streamError
{
	return ( [[streamError retain] autorelease] );
}

- (void) scheduleInRunLoop: (NSRunLoop *) runLoop forMode: (NSString *) mode
{
	[_connection scheduleInRunLoop: runLoop forMode: mode];
}

- (void) removeFromRunLoop: (NSRunLoop *) runLoop forMode: (NSString *) mode
{
	[_connection unscheduleFromRunLoop: runLoop forMode: mode];
}

- (id<NSStreamDelegate>) delegate
{
	return ( _delegate );
}

- (void) setDelegate: (id<NSStreamDelegate>) aDelegate
{
	_delegate = aDelegate;
}

- (id) propertyForKey: (NSString *) key
{
	if ( [key isEqualToString: AQStreamPropertyURLRequest] )
		return ( [[_request retain] autorelease] );
	if ( [key isEqualToString: (NSString *)kCFStreamPropertyHTTPFinalRequest] )
		return ( [NSMakeCollectable([self copyCFRequestMessage]) autorelease] );
	
	if ( [key isEqualToString: AQStreamPropertyURLResponse] )
		return ( [[_request retain] autorelease] );
	if ( [key isEqualToString: (NSString *)kCFStreamPropertyHTTPResponseHeader] )
		return ( [NSMakeCollectable([self copyCFResponseMessage]) autorelease] );
	
	id result = [_properties objectForKey: key];
	if ( result != nil )
		return ( result );
	
	return ( [super propertyForKey: key] );
}

- (BOOL) setProperty: (id) property forKey: (NSString *) key
{
	BOOL result = [super setProperty: property forKey: key];
	if ( result == NO )
		[_properties setObject: property forKey: key];
	return ( YES );
}

- (NSInteger) read: (uint8_t *) buffer maxLength: (NSUInteger) len
{
	if ( _streamStatus != NSStreamStatusOpen )
		return ( -1 );
	
	_streamStatus = NSStreamStatusReading;
	
	NSInteger readLen = 0;
	if ( [_buffer length] != 0 )
	{
		len = MIN(len, [_buffer length]);
		[_buffer getBytes: buffer length: len];
		[_buffer replaceBytesInRange: NSMakeRange(0, len) withBytes: NULL length: 0];
		readLen = len;
	}
	
	_streamStatus = NSStreamStatusOpen;
	return ( readLen );
}

- (BOOL) getBuffer: (uint8_t **) buffer length: (NSUInteger *) len
{
	if ( _streamStatus != NSStreamStatusOpen )
		return ( NO );
	
	*buffer = [_buffer mutableBytes];
	*len = [_buffer length];
	return ( YES );
}

- (BOOL) hasBytesAvailable
{
	return ( [_buffer length] != 0 );
}

#pragma mark - NSURLConnection Delegate

- (NSURLRequest *) connection: (NSURLConnection *) connection willSendRequest: (NSURLRequest *) request redirectResponse: (NSURLResponse *) response
{
	[request retain];
	[_request release];
	_request = request;
	
	if ( response != nil )
	{
		[response retain];
		[_response release];
		_response = response;
	}
	
	return ( request );
}

- (void) connection: (NSURLConnection *) connection didReceiveResponse: (NSURLResponse *) response
{
	response = [response copy];
	[_response release];
	_response = response;
	
	if ( _streamStatus == NSStreamStatusOpening )
	{
		_streamStatus = NSStreamStatusOpen;
		[_delegate stream: self handleEvent: NSStreamEventOpenCompleted];
	}
}

- (void) connection: (NSURLConnection *) connection didReceiveData: (NSData *) data
{
	if ( _streamStatus == NSStreamStatusOpening )
	{
		_streamStatus = NSStreamStatusOpen;
		[_delegate stream: self handleEvent: NSStreamEventOpenCompleted];
	}
	
	[_buffer appendData: data];
	NSUInteger bufLen = 0;
	
	// we break when we run out of data, are closed, or when the delegate doesn't read any bytes
	do
	{
		bufLen = [_buffer length];
		[_delegate stream: self handleEvent: NSStreamEventHasBytesAvailable];
		
	} while ( (bufLen != [_buffer length]) && (_streamStatus == NSStreamStatusOpen) && ([_buffer length] > 0) );
}

- (void) connection: (NSURLConnection *) connection didFailWithError: (NSError *) error
{
	_streamError = [error copy];
	_streamStatus = NSStreamStatusError;
	[_delegate stream: self handleEvent: NSStreamEventErrorOccurred];
}

- (void) connectionDidFinishLoading: (NSURLConnection *) connection
{
	_streamStatus = NSStreamStatusAtEnd;
	[_delegate stream: self handleEvent: NSStreamEventEndEncountered];
}

@end
