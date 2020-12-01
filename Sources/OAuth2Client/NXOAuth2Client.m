//
//  NXOAuth2Client.m
//  OAuth2Client
//
//  Created by Ullrich Schäfer on 27.08.10.
//
//  Copyright 2010 nxtbgthng. All rights reserved.
//
//  Licenced under the new BSD-licence.
//  See README.md in this repository for
//  the full licence.
//

#import "NXOAuth2Connection.h"
#import "NXOAuth2ConnectionDelegate.h"
#import "NXOAuth2AccessToken.h"

#import "NSURL+NXOAuth2.h"

#import "NXOAuth2Client.h"


NSString * const NXOAuth2ClientConnectionContextTokenRequest = @"tokenRequest";
NSString * const NXOAuth2ClientConnectionContextTokenRefresh = @"tokenRefresh";


@interface NXOAuth2Client ()
@property (nonatomic, readwrite, getter = isAuthenticating) BOOL authenticating;

- (void)requestTokenWithAuthGrant:(NSString *)authGrant redirectURL:(NSURL *)redirectURL;
- (void)removeConnectionFromWaitingQueue:(NXOAuth2Connection *)aConnection;
@end


@implementation NXOAuth2Client


#pragma mark Lifecycle

- (instancetype)initWithClientID:(NSString *)aClientId
                    clientSecret:(NSString *)aClientSecret
                    authorizeURL:(NSURL *)anAuthorizeURL
                        tokenURL:(NSURL *)aTokenURL
                        delegate:(NSObject<NXOAuth2ClientDelegate> *)aDelegate;
{
    return [self initWithClientID:aClientId
                     clientSecret:aClientSecret
                     authorizeURL:anAuthorizeURL
                         tokenURL:aTokenURL
                      accessToken:nil
                    keyChainGroup:nil
              keyChainAccessGroup:nil
                       persistent:YES
                         delegate:aDelegate];
}

- (instancetype)initWithClientID:(NSString *)aClientId
                    clientSecret:(NSString *)aClientSecret
                    authorizeURL:(NSURL *)anAuthorizeURL
                        tokenURL:(NSURL *)aTokenURL
                     accessToken:(NXOAuth2AccessToken *)anAccessToken
                   keyChainGroup:(NSString *)aKeyChainGroup
             keyChainAccessGroup:(NSString *)aKeyChainAccessGroup
                      persistent:(BOOL)shouldPersist
                        delegate:(NSObject<NXOAuth2ClientDelegate> *)aDelegate;
{
    return [self initWithClientID:aClientId
                     clientSecret:aClientSecret
                     authorizeURL:anAuthorizeURL
                         tokenURL:aTokenURL
                      accessToken:anAccessToken
                        tokenType:nil
                    keyChainGroup:aKeyChainGroup
              keyChainAccessGroup:aKeyChainAccessGroup
                       persistent:shouldPersist
                         delegate:aDelegate];
}

- (instancetype)initWithClientID:(NSString *)aClientId
                    clientSecret:(NSString *)aClientSecret
                    authorizeURL:(NSURL *)anAuthorizeURL
                        tokenURL:(NSURL *)aTokenURL
                     accessToken:(NXOAuth2AccessToken *)anAccessToken
                       tokenType:(NSString *)aTokenType
                   keyChainGroup:(NSString *)aKeyChainGroup
             keyChainAccessGroup:(NSString *)aKeyChainAccessGroup
                      persistent:(BOOL)shouldPersist
                        delegate:(NSObject<NXOAuth2ClientDelegate> *)aDelegate;
{
    NSAssert(aTokenURL != nil && anAuthorizeURL != nil, @"No token or no authorize URL");
    self = [super init];
    if (self) {
        refreshConnectionDidRetryCount = 0;
        
        clientId = [aClientId copy];
        clientSecret = [aClientSecret copy];
        authorizeURL = [anAuthorizeURL copy];
        tokenURL = [aTokenURL copy];
        tokenType = [aTokenType copy];
        accessToken = anAccessToken;
        
        self.tokenRequestHTTPMethod = @"POST";
        self.acceptType = @"application/json";
        keyChainGroup = aKeyChainGroup;
        keyChainAccessGroup = aKeyChainAccessGroup;
        
        self.persistent = shouldPersist;
        self.delegate = aDelegate;
    }
    return self;
}

- (void)dealloc;
{
    [authConnection cancel];
}


#pragma mark Accessors

@synthesize clientId, clientSecret, tokenType;
@synthesize desiredScope, userAgent;
@synthesize delegate, persistent, accessToken, authenticating;
@synthesize additionalAuthenticationParameters;
@synthesize authConnection = authConnection;

- (void)setAdditionalAuthenticationParameters:(NSDictionary *)value;
{
    if (value == additionalAuthenticationParameters) return;
    
    NSArray *forbiddenKeys = @[ @"grant_type", @"client_id",
                                @"client_secret",
                                @"username", @"password",
                                @"redirect_uri", @"code",
                                @"assertion_type", @"assertion" ];
    
    for (id key in value) {
        if ([forbiddenKeys containsObject:key]) {
            [[NSException exceptionWithName:NSInvalidArgumentException
                                     reason:[NSString stringWithFormat:@"'%@' is not allowed as a key for additionalAuthenticationParameters", key]
                                   userInfo:nil] raise];
        }
    }
    
    additionalAuthenticationParameters = value;
    
    
}

- (void)setPersistent:(BOOL)shouldPersist;
{
    NSLog(@"*******persistent in %@*****class function******%s****  is****%d**** accessToken is %@ and refreshToken is %@: shouldpersist is %d",[self class],__PRETTY_FUNCTION__,persistent,accessToken.accessToken,accessToken.refreshToken,shouldPersist);
    if (persistent == shouldPersist) return;
    
    if (shouldPersist && accessToken) {
        [self.accessToken storeInDefaultKeychainWithServiceProviderName:keyChainGroup ? keyChainGroup : [tokenURL host]
                                                 withAccessGroup:keyChainAccessGroup];
    }
    
    if (persistent && !shouldPersist) {
        [accessToken removeFromDefaultKeychainWithServiceProviderName:keyChainGroup ? keyChainGroup : [tokenURL host]
                                               withAccessGroup:keyChainAccessGroup];
    }

    [self willChangeValueForKey:@"persistent"];
    persistent = shouldPersist;
    [self didChangeValueForKey:@"persistent"];
}

- (NXOAuth2AccessToken *)accessToken;
{
    if (accessToken) return accessToken;
    
    if (persistent) {
        accessToken = [NXOAuth2AccessToken tokenFromDefaultKeychainWithServiceProviderName:keyChainGroup ? keyChainGroup : [tokenURL host]
                                                                    withAccessGroup:keyChainAccessGroup];
        if (accessToken) {
            if ([delegate respondsToSelector:@selector(oauthClientDidGetAccessToken:)]) {
                [delegate oauthClientDidGetAccessToken:self];
            }
        }
        return accessToken;
    } else {
        return nil;
    }
}

- (void)setAccessToken:(NXOAuth2AccessToken *)value;
{
    if (self.accessToken == value) return;
    BOOL authorisationStatusChanged = ((accessToken == nil)    || (value == nil)); //They can't both be nil, see one line above. So they have to have changed from or to nil.
    
    if (!value) {
        [self.accessToken removeFromDefaultKeychainWithServiceProviderName:keyChainGroup ? keyChainGroup : [tokenURL host]
                                                    withAccessGroup:keyChainAccessGroup];
    }
    
    [self willChangeValueForKey:@"accessToken"];
    accessToken = value;
    [self didChangeValueForKey:@"accessToken"];
    
    if (persistent) {
        [accessToken storeInDefaultKeychainWithServiceProviderName:keyChainGroup ? keyChainGroup : [tokenURL host]
                                            withAccessGroup:keyChainAccessGroup];
    }
    NSLog(@"^^^^authorisationStatusChanged is ^^^%s^^",authorisationStatusChanged ? "true" : "false");
    if (authorisationStatusChanged) {
        if (accessToken) {
            if ([delegate respondsToSelector:@selector(oauthClientDidGetAccessToken:)]) {
                [delegate oauthClientDidGetAccessToken:self];
            }
        } else {
            if ([delegate respondsToSelector:@selector(oauthClientDidLoseAccessToken:)]) {
                [delegate oauthClientDidLoseAccessToken:self];
            }
        }
    } else {
        if ([delegate respondsToSelector:@selector(oauthClientDidRefreshAccessToken:)]) {
            [delegate oauthClientDidRefreshAccessToken:self];
        }
    }
}

- (void)setDesiredScope:(NSSet *)aDesiredScope;
{
    if (desiredScope == aDesiredScope) {
        return;
    }
    
    desiredScope = [aDesiredScope copy];
}


#pragma mark Flow

- (void)requestAccess;
{
    [self requestAccessAndRetryConnection:nil];
}

- (void)requestAccessAndRetryConnection:(NXOAuth2Connection *)retryConnection
{
    if (!self.accessToken) {
        
        if (retryConnection) {
            if (!waitingConnections) waitingConnections = [[NSMutableArray alloc] init];
            [waitingConnections addObject:retryConnection];
        }
        
        [delegate oauthClientNeedsAuthentication:self];
    }
}

- (NSMutableString *)getRandomString:(NSInteger)length
{
    NSString *letters = @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~";
    NSMutableString *randomString = [NSMutableString stringWithCapacity:length];

    for (int i = 0; i < length; i++) {
        [randomString appendFormat:@"%C", [letters characterAtIndex:arc4random() % [letters length]]];
    }

    return randomString;
}

- (NSString *)getb64s256string:(NSInteger) length{
    self.codeVerifier = @"";
    NSMutableString *randomStringForCodeChallenge = [self getRandomString:60];
    self.codeVerifier = randomStringForCodeChallenge;
    NSData *verifierData = [randomStringForCodeChallenge dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *sha256Verifier = [NSMutableData dataWithLength:CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(verifierData.bytes, (CC_LONG)verifierData.length, sha256Verifier.mutableBytes);
    return [self encodeBase64urlNoPadding:sha256Verifier];
    
}

- (NSString *)encodeBase64urlNoPadding:(NSMutableData *)data {
  NSString *base64string = [data base64EncodedStringWithOptions:0];
  // converts base64 to base64url
  base64string = [base64string stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
  base64string = [base64string stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
  // strips padding
  base64string = [base64string stringByReplacingOccurrencesOfString:@"=" withString:@""];
  return base64string;
}

- (NSURL *)authorizationURLWithRedirectURL:(NSURL *)redirectURL;
{
    self.base64s256CodeChallenge = @"";
    self.base64s256CodeChallenge = [self getb64s256string:60];
    NSMutableDictionary *parameters = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                       @"code", @"response_type",
                                       @"egjkaengngeoia3q24241542", @"state",
                                       @"openid api://29cd31e5-0ac5-441c-b435-7ea0c8709dde/ApiGatewayNonProd email profile Offline_access", @"scope",
                                       @"XYs54n9QFB2wcxXVtX_Ji4iep5kETsWCRmP-tehUbC0", @"code_challenge", // self.base64s256CodeChallenge
                                       @"S256", @"code_challenge_method",
                                       clientId, @"client_id",
                                       [redirectURL absoluteString], @"redirect_uri",
                                       nil];
    // openid%20api%3A%2F%2F29cd31e5-0ac5-441c-b435-7ea0c8709dde%2FApiGatewayNonProd%20email%20profile%20Offline_access


    
    if (self.additionalAuthenticationParameters) {
        [parameters addEntriesFromDictionary:self.additionalAuthenticationParameters];
    }
    
    if (self.desiredScope.count > 0) {
        [parameters setObject:[[self.desiredScope allObjects] componentsJoinedByString:@" "] forKey:@"scope"];
    }
    
    return [authorizeURL nxoauth2_URLByAddingParameters:parameters];
}

// Web Server Flow only
- (BOOL)openRedirectURL:(NSURL *)URL;
{
    return [self openRedirectURL:URL error:nil];
}

- (BOOL)openRedirectURL:(NSURL *)URL error: (NSError**) error;
{
    NSString *accessGrant = [URL nxoauth2_valueForQueryParameterKey:@"code"];
    if (accessGrant) {
        [self requestTokenWithAuthGrant:accessGrant redirectURL:[URL nxoauth2_URLWithoutQueryString]];
        return YES;
    }
    else{
        NSError* oauthError = [URL nxoauth2_redirectURLError];
        if (oauthError && error) {
            *error = oauthError;
        }
        if ([delegate respondsToSelector:@selector(oauthClient:didFailToGetAccessTokenWithError:)]) {
            [delegate oauthClient:self didFailToGetAccessTokenWithError: oauthError];
        }
        return NO;
    }
}

#pragma mark Request Token

// Web Server Flow only
- (void)requestTokenWithAuthGrant:(NSString *)authGrant redirectURL:(NSURL *)redirectURL;
{
    NSAssert1(!authConnection, @"authConnection already running with: %@", authConnection);
    
    NSMutableURLRequest *tokenRequest = [NSMutableURLRequest requestWithURL:tokenURL];
    [tokenRequest setHTTPMethod:self.tokenRequestHTTPMethod];
    [authConnection cancel];  // just to be sure

    self.authenticating = YES;

    NSMutableDictionary *parameters = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                       @"authorization_code", @"grant_type",
                                       clientId, @"client_id",
                                       //clientSecret, @"client_secret",
                                       self.codeVerifier, @"code_verifier",
                                       [redirectURL absoluteString], @"redirect_uri",
                                       authGrant, @"code",
                                       nil];
    if (self.desiredScope) {
        [parameters setObject:[[self.desiredScope allObjects] componentsJoinedByString:@" "] forKey:@"scope"];
    }
    
    if (self.customHeaderFields) {
        [self.customHeaderFields enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *obj, BOOL *stop) {
            [tokenRequest addValue:obj forHTTPHeaderField:key];
        }];
    }
    
    if (self.additionalAuthenticationParameters) {
        [parameters addEntriesFromDictionary:self.additionalAuthenticationParameters];
    }
    
    authConnection = [[NXOAuth2Connection alloc] initWithRequest:tokenRequest
                                               requestParameters:parameters
                                                     oauthClient:self
                                                        delegate:self];
    authConnection.context = NXOAuth2ClientConnectionContextTokenRequest;
}

// Client Credential Flow
- (void)authenticateWithClientCredentials;
{
    NSAssert1(!authConnection, @"authConnection already running with: %@", authConnection);
    
    NSMutableURLRequest *tokenRequest = [NSMutableURLRequest requestWithURL:tokenURL];
    [tokenRequest setHTTPMethod:self.tokenRequestHTTPMethod];
    [authConnection cancel];  // just to be sure
    
    self.authenticating = YES;
    
    NSMutableDictionary *parameters = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                       @"client_credentials", @"grant_type",
                                       clientId, @"client_id",
                                       clientSecret, @"client_secret",
                                       nil];
    if (self.desiredScope) {
        [parameters setObject:[[self.desiredScope allObjects] componentsJoinedByString:@" "] forKey:@"scope"];
    }
    
    if (self.customHeaderFields) {
        [self.customHeaderFields enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *obj, BOOL *stop) {
            [tokenRequest addValue:obj forHTTPHeaderField:key];
        }];
    }
    
    authConnection = [[NXOAuth2Connection alloc] initWithRequest:tokenRequest
                                               requestParameters:parameters
                                                     oauthClient:self
                                                        delegate:self];
    authConnection.context = NXOAuth2ClientConnectionContextTokenRequest;
}

// User Password Flow Only
- (void)authenticateWithUsername:(NSString *)username password:(NSString *)password;
{
    NSAssert1(!authConnection, @"authConnection already running with: %@", authConnection);
    
    NSMutableURLRequest *tokenRequest = [NSMutableURLRequest requestWithURL:tokenURL];
    [tokenRequest setHTTPMethod:self.tokenRequestHTTPMethod];
    [authConnection cancel];  // just to be sure

    self.authenticating = YES;

    NSMutableDictionary *parameters = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                       @"password", @"grant_type",
                                       clientId, @"client_id",
                                       clientSecret, @"client_secret",
                                       username, @"username",
                                       password, @"password",
                                       nil];
    if (self.desiredScope) {
        [parameters setObject:[[self.desiredScope allObjects] componentsJoinedByString:@" "] forKey:@"scope"];
    }
    
    if (self.additionalAuthenticationParameters) {
        [parameters addEntriesFromDictionary:self.additionalAuthenticationParameters];
    }
    
    if (self.customHeaderFields) {
        [self.customHeaderFields enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *obj, BOOL *stop) {
            [tokenRequest addValue:obj forHTTPHeaderField:key];
        }];
    }
    
    authConnection = [[NXOAuth2Connection alloc] initWithRequest:tokenRequest
                                               requestParameters:parameters
                                                     oauthClient:self
                                                        delegate:self];
    authConnection.context = NXOAuth2ClientConnectionContextTokenRequest;
}

// Assertion
- (void)authenticateWithAssertionType:(NSURL *)anAssertionType assertion:(NSString *)anAssertion;
{
    NSAssert1(!authConnection, @"authConnection already running with: %@", authConnection);
    NSParameterAssert(anAssertionType);
    NSParameterAssert(anAssertion);
    
    NSMutableURLRequest *tokenRequest = [NSMutableURLRequest requestWithURL:tokenURL];
    [tokenRequest setHTTPMethod:self.tokenRequestHTTPMethod];
    [authConnection cancel];  // just to be sure
    
    self.authenticating = YES;
    
    NSMutableDictionary *parameters = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                       @"assertion", @"grant_type",
                                       clientId, @"client_id",
                                       clientSecret, @"client_secret",
                                       anAssertionType.absoluteString, @"assertion_type",
                                       anAssertion, @"assertion",
                                       nil];
    if (self.desiredScope) {
        [parameters setObject:[[self.desiredScope allObjects] componentsJoinedByString:@" "] forKey:@"scope"];
    }
    authConnection = [[NXOAuth2Connection alloc] initWithRequest:tokenRequest
                                               requestParameters:parameters
                                                     oauthClient:self
                                                        delegate:self];
    authConnection.context = NXOAuth2ClientConnectionContextTokenRequest;
}

#pragma mark Public

- (void)refreshAccessToken
{
    [self refreshAccessTokenAndRetryConnection:nil];
}

- (void)refreshAccessTokenAndRetryConnection:(NXOAuth2Connection *)retryConnection;
{
    if (retryConnection) {
        if (!waitingConnections) waitingConnections = [[NSMutableArray alloc] init];
        [waitingConnections addObject:retryConnection];
    }
    NSLog(@"*******Refresh token in %@***** is****%@****",[self class],accessToken.refreshToken);
    if (!authConnection) {
        NSAssert((accessToken.refreshToken != nil), @"invalid state");
        NSMutableURLRequest *tokenRequest = [NSMutableURLRequest requestWithURL:tokenURL];
        [tokenRequest setHTTPMethod:self.tokenRequestHTTPMethod];
        [authConnection cancel]; // not needed, but looks more clean to me :)
        
        NSMutableDictionary *parameters = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                           @"refresh_token", @"grant_type",
                                           clientId, @"client_id",
                                           clientSecret, @"client_secret",
                                           accessToken.refreshToken, @"refresh_token",
                                           nil];
        if (self.desiredScope) {
            [parameters setObject:[[self.desiredScope allObjects] componentsJoinedByString:@" "] forKey:@"scope"];
        }
        NSLog(@"*******Parameters in %@*****class  is****%@****",[self class],parameters);
        authConnection = [[NXOAuth2Connection alloc] initWithRequest:tokenRequest
                                                   requestParameters:parameters
                                                         oauthClient:self
                                                            delegate:self];
        authConnection.context = NXOAuth2ClientConnectionContextTokenRefresh;
    }
}

- (void)removeConnectionFromWaitingQueue:(NXOAuth2Connection *)aConnection;
{
    if (!aConnection) return;
    [waitingConnections removeObject:aConnection];
}


#pragma mark NXOAuth2ConnectionDelegate

- (void)oauthConnection:(NXOAuth2Connection *)connection didFinishWithData:(NSData *)data;
{
    if (connection == authConnection) {
        self.authenticating = NO;

        NSString *result = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        NXOAuth2AccessToken *newToken = [NXOAuth2AccessToken tokenWithResponseBody:result tokenType:self.tokenType
                                         ];
        NSAssert(newToken != nil, @"invalid response?");
         NSLog(@"*******result in %@*****class function******%s****  is****%@****",[self class],__PRETTY_FUNCTION__,result);
        NSLog(@"*******new token in %@*****class function******%s****  is****%@**** self.accessToken.refreshToken is **%@**",[self class],__PRETTY_FUNCTION__,newToken.refreshToken,self.accessToken.refreshToken);
        [newToken restoreWithOldToken:self.accessToken];
        
        self.accessToken = newToken;
        
        for (NXOAuth2Connection *retryConnection in waitingConnections) {
            [retryConnection retry];
        }
        [waitingConnections removeAllObjects];
        
        authConnection = nil;
        
        refreshConnectionDidRetryCount = 0;    // reset
    }
}

- (void)oauthConnection:(NXOAuth2Connection *)connection didFailWithError:(NSError *)error;
{
    NSString *body = [[NSString alloc] initWithData:connection.data encoding:NSUTF8StringEncoding];
    NSLog(@"oauthConnection Error: %@", body);
    
    NSLog(@"*******error in %@*****class function******%s****  is****%@****",[self class],__PRETTY_FUNCTION__,error.debugDescription);
    //NSLog(@"*******new token in %@*****class function******%s****  is****%@****",[self class],__PRETTY_FUNCTION__,newToken);
    
    if (connection == authConnection) {
        self.authenticating = NO;

        id context = connection.context;
        authConnection = nil;
        
        if ([context isEqualToString:NXOAuth2ClientConnectionContextTokenRefresh]
            && [[error domain] isEqualToString:NXOAuth2HTTPErrorDomain]
            && error.code >= 500 && error.code < 600
            && refreshConnectionDidRetryCount < 4) {
            
            // no token refresh because of a server issue. don't give up just yet.
            [self performSelector:@selector(refreshAccessToken) withObject:nil afterDelay:1];
            refreshConnectionDidRetryCount++;
            
        } else {
            if ([context isEqualToString:NXOAuth2ClientConnectionContextTokenRefresh]) {
                NSError *retryFailedError = [NSError errorWithDomain:NXOAuth2ErrorDomain
                                                                code:NXOAuth2CouldNotRefreshTokenErrorCode
                                                            userInfo:[NSDictionary dictionaryWithObjectsAndKeys:
                                                                      NSLocalizedString(@"Access token could not be refreshed", @"NXOAuth2CouldNotRefreshTokenErrorCode description"), NSLocalizedDescriptionKey,
                                                                      nil]];
                
                NSArray *failedConnections = [waitingConnections copy];
                [waitingConnections removeAllObjects];
                for (NXOAuth2Connection *connection in failedConnections) {
                    id<NXOAuth2ConnectionDelegate> connectionDelegate = connection.delegate;
                        if ([connectionDelegate respondsToSelector:@selector(oauthConnection:didFailWithError:)]) {
                        [connectionDelegate oauthConnection:connection didFailWithError:retryFailedError];
                    }
                }
            }
            
            if ([[error domain] isEqualToString:NXOAuth2HTTPErrorDomain]
                && error.code == 401) {
                self.accessToken = nil;        // reset the token since it got invalid
            }
            
            if ([delegate respondsToSelector:@selector(oauthClient:didFailToGetAccessTokenWithError:)]) {
                [delegate oauthClient:self didFailToGetAccessTokenWithError:error];
            }
        }
    }
}

@end
