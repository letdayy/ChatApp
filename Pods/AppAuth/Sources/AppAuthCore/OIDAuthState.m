/*! @file OIDAuthState.m
    @brief AppAuth iOS SDK
    @copyright
        Copyright 2015 Google Inc. All Rights Reserved.
    @copydetails
        Licensed under the Apache License, Version 2.0 (the "License");
        you may not use this file except in compliance with the License.
        You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

        Unless required by applicable law or agreed to in writing, software
        distributed under the License is distributed on an "AS IS" BASIS,
        WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
        See the License for the specific language governing permissions and
        limitations under the License.
 */

#import "OIDAuthState.h"

#import "OIDAuthStateChangeDelegate.h"
#import "OIDAuthStateErrorDelegate.h"
#import "OIDAuthorizationRequest.h"
#import "OIDAuthorizationResponse.h"
#import "OIDAuthorizationService.h"
#import "OIDDefines.h"
#import "OIDError.h"
#import "OIDErrorUtilities.h"
#import "OIDRegistrationResponse.h"
#import "OIDTokenRequest.h"
#import "OIDTokenResponse.h"
#import "OIDTokenUtilities.h"

/*! @brief Key used to encode the @c refreshToken property for @c NSSecureCoding.
 */
static NSString *const kRefreshTokenKey = @"refreshToken";

/*! @brief Key used to encode the @c needsTokenRefresh property for @c NSSecureCoding.
 */
static NSString *const kNeedsTokenRefreshKey = @"needsTokenRefresh";

/*! @brief Key used to encode the @c scope property for @c NSSecureCoding.
 */
static NSString *const kScopeKey = @"scope";

/*! @brief Key used to encode the @c lastAuthorizationResponse property for @c NSSecureCoding.
 */
static NSString *const kLastAuthorizationResponseKey = @"lastAuthorizationResponse";

/*! @brief Key used to encode the @c lastTokenResponse property for @c NSSecureCoding.
 */
static NSString *const kLastTokenResponseKey = @"lastTokenResponse";

/*! @brief Key used to encode the @c lastOAuthError property for @c NSSecureCoding.
 */
static NSString *const kAuthorizationErrorKey = @"authorizationError";

/*! @brief Number of seconds the access token is refreshed before it actually expires.
 */
static const NSUInteger kExpiryTimeTolerance = 60;

/*! @brief Object to hold OIDAuthState pending actions.
 */
@interface OIDAuthStatePendingAction : NSObject
@property(nonatomic, readonly, nullable) OIDAuthStateAction action;
@property(nonatomic, readonly, nullable) dispatch_queue_t dispatchQueue;
@end
@implementation OIDAuthStatePendingAction
- (id)initWithAction:(OIDAuthStateAction)action andDispatchQueue:(dispatch_queue_t)dispatchQueue {
  self = [super init];
  if (self) {
    _action = action;
    _dispatchQueue = dispatchQueue;
  }
  return self;
}
@end

@interface OIDAuthState ()

/*! @brief The access token generated by the authorization server.
    @discussion Rather than using this property directly, you should call
        @c OIDAuthState.withFreshTokenPerformAction:.
 */
@property(nonatomic, readonly, nullable) NSString *accessToken;

/*! @brief The approximate expiration date & time of the access token.
    @discussion Rather than using this property directly, you should call
        @c OIDAuthState.withFreshTokenPerformAction:.
 */
@property(nonatomic, readonly, nullable) NSDate *accessTokenExpirationDate;

/*! @brief ID Token value associated with the authenticated session.
    @discussion Rather than using this property directly, you should call
        OIDAuthState.withFreshTokenPerformAction:.
 */
@property(nonatomic, readonly, nullable) NSString *idToken;

/*! @brief Private method, called when the internal state changes.
 */
- (void)didChangeState;

@end


@implementation OIDAuthState {
  /*! @brief Array of pending actions (use @c _pendingActionsSyncObject to synchronize access).
   */
  NSMutableArray *_pendingActions;

  /*! @brief Object for synchronizing access to @c pendingActions.
   */
  id _pendingActionsSyncObject;

  /*! @brief If YES, tokens will be refreshed on the next API call regardless of expiry.
   */
  BOOL _needsTokenRefresh;
}

#pragma mark - Convenience initializers

+ (id<OIDExternalUserAgentSession>)
    authStateByPresentingAuthorizationRequest:(OIDAuthorizationRequest *)authorizationRequest
                            externalUserAgent:(id<OIDExternalUserAgent>)externalUserAgent
                                     callback:(OIDAuthStateAuthorizationCallback)callback {
  // presents the authorization request
  id<OIDExternalUserAgentSession> authFlowSession = [OIDAuthorizationService
      presentAuthorizationRequest:authorizationRequest
                externalUserAgent:externalUserAgent
                         callback:^(OIDAuthorizationResponse *_Nullable authorizationResponse,
                                    NSError *_Nullable authorizationError) {
                           // inspects response and processes further if needed (e.g. authorization
                           // code exchange)
                           if (authorizationResponse) {
                             if ([authorizationRequest.responseType
                                     isEqualToString:OIDResponseTypeCode]) {
                               // if the request is for the code flow (NB. not hybrid), assumes the
                               // code is intended for this client, and performs the authorization
                               // code exchange
                               OIDTokenRequest *tokenExchangeRequest =
                                   [authorizationResponse tokenExchangeRequest];
                               [OIDAuthorizationService performTokenRequest:tokenExchangeRequest
                                              originalAuthorizationResponse:authorizationResponse
                                   callback:^(OIDTokenResponse *_Nullable tokenResponse,
                                                         NSError *_Nullable tokenError) {
                                                OIDAuthState *authState;
                                                if (tokenResponse) {
                                                  authState = [[OIDAuthState alloc]
                                                      initWithAuthorizationResponse:
                                                          authorizationResponse
                                                                      tokenResponse:tokenResponse];
                                                }
                                                callback(authState, tokenError);
                               }];
                             } else {
                               // hybrid flow (code id_token). Two possible cases:
                               // 1. The code is not for this client, ie. will be sent to a
                               //    webservice that performs the id token verification and token
                               //    exchange
                               // 2. The code is for this client and, for security reasons, the
                               //    application developer must verify the id_token signature and
                               //    c_hash before calling the token endpoint
                               OIDAuthState *authState = [[OIDAuthState alloc]
                                   initWithAuthorizationResponse:authorizationResponse];
                               callback(authState, authorizationError);
                             }
                           } else {
                             callback(nil, authorizationError);
                           }
                         }];
  return authFlowSession;
}

#pragma mark - Initializers

- (nonnull instancetype)init
    OID_UNAVAILABLE_USE_INITIALIZER(@selector(initWithAuthorizationResponse:tokenResponse:))

/*! @brief Creates an auth state from an authorization response.
    @param authorizationResponse The authorization response.
 */
- (instancetype)initWithAuthorizationResponse:(OIDAuthorizationResponse *)authorizationResponse {
  return [self initWithAuthorizationResponse:authorizationResponse tokenResponse:nil];
}


/*! @brief Designated initializer.
    @param authorizationResponse The authorization response.
    @discussion Creates an auth state from an authorization response and token response.
 */
- (instancetype)initWithAuthorizationResponse:(OIDAuthorizationResponse *)authorizationResponse
                                         tokenResponse:(nullable OIDTokenResponse *)tokenResponse {
  return [self initWithAuthorizationResponse:authorizationResponse
                               tokenResponse:tokenResponse
                        registrationResponse:nil];
}

/*! @brief Creates an auth state from an registration response.
    @param registrationResponse The registration response.
 */
- (instancetype)initWithRegistrationResponse:(OIDRegistrationResponse *)registrationResponse {
  return [self initWithAuthorizationResponse:nil
                               tokenResponse:nil
                        registrationResponse:registrationResponse];
}

- (instancetype)initWithAuthorizationResponse:
    (nullable OIDAuthorizationResponse *)authorizationResponse
           tokenResponse:(nullable OIDTokenResponse *)tokenResponse
    registrationResponse:(nullable OIDRegistrationResponse *)registrationResponse {
  self = [super init];
  if (self) {
    _pendingActionsSyncObject = [[NSObject alloc] init];

    if (registrationResponse) {
      [self updateWithRegistrationResponse:registrationResponse];
    }

    if (authorizationResponse) {
      [self updateWithAuthorizationResponse:authorizationResponse error:nil];
    }

    if (tokenResponse) {
      [self updateWithTokenResponse:tokenResponse error:nil];
    }
  }
  return self;
}

#pragma mark - NSObject overrides

- (NSString *)description {
  return [NSString stringWithFormat:@"<%@: %p, isAuthorized: %@, refreshToken: \"%@\", "
                                     "scope: \"%@\", accessToken: \"%@\", "
                                     "accessTokenExpirationDate: %@, idToken: \"%@\", "
                                     "lastAuthorizationResponse: %@, lastTokenResponse: %@, "
                                     "lastRegistrationResponse: %@, authorizationError: %@>",
                                    NSStringFromClass([self class]),
                                    (void *)self,
                                    (self.isAuthorized) ? @"YES" : @"NO",
                                    [OIDTokenUtilities redact:_refreshToken],
                                    _scope,
                                    [OIDTokenUtilities redact:self.accessToken],
                                    self.accessTokenExpirationDate,
                                    [OIDTokenUtilities redact:self.idToken],
                                    _lastAuthorizationResponse,
                                    _lastTokenResponse,
                                    _lastRegistrationResponse,
                                    _authorizationError];
}

#pragma mark - NSSecureCoding

+ (BOOL)supportsSecureCoding {
  return YES;
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
  _lastAuthorizationResponse = [aDecoder decodeObjectOfClass:[OIDAuthorizationResponse class]
                                                      forKey:kLastAuthorizationResponseKey];
  _lastTokenResponse = [aDecoder decodeObjectOfClass:[OIDTokenResponse class]
                                              forKey:kLastTokenResponseKey];
  self = [self initWithAuthorizationResponse:_lastAuthorizationResponse
                               tokenResponse:_lastTokenResponse];
  if (self) {
    _authorizationError =
        [aDecoder decodeObjectOfClass:[NSError class] forKey:kAuthorizationErrorKey];
    _scope = [aDecoder decodeObjectOfClass:[NSString class] forKey:kScopeKey];
    _refreshToken = [aDecoder decodeObjectOfClass:[NSString class] forKey:kRefreshTokenKey];
    _needsTokenRefresh = [aDecoder decodeBoolForKey:kNeedsTokenRefreshKey];
  }
  return self;
}

- (void)encodeWithCoder:(NSCoder *)aCoder {
  [aCoder encodeObject:_lastAuthorizationResponse forKey:kLastAuthorizationResponseKey];
  [aCoder encodeObject:_lastTokenResponse forKey:kLastTokenResponseKey];
  if (_authorizationError) {
    NSError *codingSafeAuthorizationError = [NSError errorWithDomain:_authorizationError.domain
                                                                code:_authorizationError.code
                                                            userInfo:nil];
    [aCoder encodeObject:codingSafeAuthorizationError forKey:kAuthorizationErrorKey];
  }
  [aCoder encodeObject:_scope forKey:kScopeKey];
  [aCoder encodeObject:_refreshToken forKey:kRefreshTokenKey];
  [aCoder encodeBool:_needsTokenRefresh forKey:kNeedsTokenRefreshKey];
}

#pragma mark - Private convenience getters

- (NSString *)accessToken {
  if (_authorizationError) {
    return nil;
  }
  return _lastTokenResponse ? _lastTokenResponse.accessToken
                            : _lastAuthorizationResponse.accessToken;
}

- (NSString *)tokenType {
  if (_authorizationError) {
    return nil;
  }
  return _lastTokenResponse ? _lastTokenResponse.tokenType
                            : _lastAuthorizationResponse.tokenType;
}

- (NSDate *)accessTokenExpirationDate {
  if (_authorizationError) {
    return nil;
  }
  return _lastTokenResponse ? _lastTokenResponse.accessTokenExpirationDate
                            : _lastAuthorizationResponse.accessTokenExpirationDate;
}

- (NSString *)idToken {
  if (_authorizationError) {
    return nil;
  }
  return _lastTokenResponse ? _lastTokenResponse.idToken
                            : _lastAuthorizationResponse.idToken;
}

#pragma mark - Getters

- (BOOL)isAuthorized {
  return !self.authorizationError && (self.accessToken || self.idToken || self.refreshToken);
}

#pragma mark - Updating the state

- (void)updateWithRegistrationResponse:(OIDRegistrationResponse *)registrationResponse {
  _lastRegistrationResponse = registrationResponse;
  _refreshToken = nil;
  _scope = nil;
  _lastAuthorizationResponse = nil;
  _lastTokenResponse = nil;
  _authorizationError = nil;
  [self didChangeState];
}

- (void)updateWithAuthorizationResponse:(nullable OIDAuthorizationResponse *)authorizationResponse
                                  error:(nullable NSError *)error {
  // If the error is an OAuth authorization error, updates the state. Other errors are ignored.
  if (error.domain == OIDOAuthAuthorizationErrorDomain) {
    [self updateWithAuthorizationError:error];
    return;
  }
  if (!authorizationResponse) {
    return;
  }

  _lastAuthorizationResponse = authorizationResponse;

  // clears the last token response and refresh token as these now relate to an old authorization
  // that is no longer relevant
  _lastTokenResponse = nil;
  _refreshToken = nil;
  _authorizationError = nil;

  // if the response's scope is nil, it means that it equals that of the request
  // see: https://tools.ietf.org/html/rfc6749#section-5.1
  _scope = (authorizationResponse.scope) ? authorizationResponse.scope
                                         : authorizationResponse.request.scope;

  [self didChangeState];
}

- (void)updateWithTokenResponse:(nullable OIDTokenResponse *)tokenResponse
                          error:(nullable NSError *)error {
  if (_authorizationError) {
    // Calling updateWithTokenResponse while in an error state probably means the developer obtained
    // a new token and did the exchange without also calling updateWithAuthorizationResponse.
    // Attempts to handle gracefully, but warns the developer that this is unexpected.
    NSLog(@"OIDAuthState:updateWithTokenResponse should not be called in an error state [%@] call"
         "updateWithAuthorizationResponse with the result of the fresh authorization response"
         "first",
         _authorizationError);

    _authorizationError = nil;
  }

  // If the error is an OAuth authorization error, updates the state. Other errors are ignored.
  if (error.domain == OIDOAuthTokenErrorDomain) {
    [self updateWithAuthorizationError:error];
    return;
  }
  if (!tokenResponse) {
    return;
  }

  _lastTokenResponse = tokenResponse;

  // updates the scope and refresh token if they are present on the TokenResponse.
  // according to the spec, these may be changed by the server, including when refreshing the
  // access token. See: https://tools.ietf.org/html/rfc6749#section-5.1 and
  // https://tools.ietf.org/html/rfc6749#section-6
  if (tokenResponse.scope) {
    _scope = tokenResponse.scope;
  }
  if (tokenResponse.refreshToken) {
    _refreshToken = tokenResponse.refreshToken;
  }

  [self didChangeState];
}

- (void)updateWithAuthorizationError:(NSError *)oauthError {
  _authorizationError = oauthError;

  [self didChangeState];

  [_errorDelegate authState:self didEncounterAuthorizationError:oauthError];
}

#pragma mark - OAuth Requests

- (OIDTokenRequest *)tokenRefreshRequest {
  return [self tokenRefreshRequestWithAdditionalParameters:nil];
}

- (OIDTokenRequest *)tokenRefreshRequestWithAdditionalParameters:
    (NSDictionary<NSString *, NSString *> *)additionalParameters {

  if (!_refreshToken) {
    [OIDErrorUtilities raiseException:kRefreshTokenRequestException];
  }
  return [[OIDTokenRequest alloc]
      initWithConfiguration:_lastAuthorizationResponse.request.configuration
                  grantType:OIDGrantTypeRefreshToken
          authorizationCode:nil
                redirectURL:nil
                   clientID:_lastAuthorizationResponse.request.clientID
               clientSecret:_lastAuthorizationResponse.request.clientSecret
                      scope:nil
               refreshToken:_refreshToken
               codeVerifier:nil
       additionalParameters:additionalParameters
          additionalHeaders:nil];
}

- (OIDTokenRequest *)tokenRefreshRequestWithAdditionalParameters:
    (NSDictionary<NSString *, NSString *> *)additionalParameters
                                               additionalHeaders:
    (NSDictionary<NSString *,NSString *> *)additionalHeaders {

  if (!_refreshToken) {
    [OIDErrorUtilities raiseException:kRefreshTokenRequestException];
  }
  return [[OIDTokenRequest alloc]
      initWithConfiguration:_lastAuthorizationResponse.request.configuration
                  grantType:OIDGrantTypeRefreshToken
          authorizationCode:nil
                redirectURL:nil
                   clientID:_lastAuthorizationResponse.request.clientID
               clientSecret:_lastAuthorizationResponse.request.clientSecret
                      scope:nil
               refreshToken:_refreshToken
               codeVerifier:nil
       additionalParameters:additionalParameters
          additionalHeaders:additionalHeaders];
}

- (OIDTokenRequest *)tokenRefreshRequestWithAdditionalHeaders:
    (NSDictionary<NSString *, NSString *> *)additionalHeaders {

  if (!_refreshToken) {
    [OIDErrorUtilities raiseException:kRefreshTokenRequestException];
  }
  return [[OIDTokenRequest alloc]
      initWithConfiguration:_lastAuthorizationResponse.request.configuration
                  grantType:OIDGrantTypeRefreshToken
          authorizationCode:nil
                redirectURL:nil
                   clientID:_lastAuthorizationResponse.request.clientID
               clientSecret:_lastAuthorizationResponse.request.clientSecret
                      scope:nil
               refreshToken:_refreshToken
               codeVerifier:nil
       additionalParameters:nil
          additionalHeaders:additionalHeaders];
}

#pragma mark - Stateful Actions

- (void)didChangeState {
  [_stateChangeDelegate didChangeState:self];
}

- (void)setNeedsTokenRefresh {
  _needsTokenRefresh = YES;
}

- (void)performActionWithFreshTokens:(OIDAuthStateAction)action {
  [self performActionWithFreshTokens:action additionalRefreshParameters:nil];
}

- (void)performActionWithFreshTokens:(OIDAuthStateAction)action
         additionalRefreshParameters:
    (nullable NSDictionary<NSString *, NSString *> *)additionalParameters {
  [self performActionWithFreshTokens:action
         additionalRefreshParameters:additionalParameters
                       dispatchQueue:dispatch_get_main_queue()];
}

- (void)performActionWithFreshTokens:(OIDAuthStateAction)action
         additionalRefreshParameters:
    (nullable NSDictionary<NSString *, NSString *> *)additionalParameters
                       dispatchQueue:(dispatch_queue_t)dispatchQueue {

  if ([self isTokenFresh]) {
    // access token is valid within tolerance levels, perform action
    dispatch_async(dispatchQueue, ^{
      action(self.accessToken, self.idToken, nil);
    });
    return;
  }

  if (!_refreshToken) {
    // no refresh token available and token has expired
    NSError *tokenRefreshError = [
      OIDErrorUtilities errorWithCode:OIDErrorCodeTokenRefreshError
                      underlyingError:nil
                          description:@"Unable to refresh expired token without a refresh token."];
    dispatch_async(dispatchQueue, ^{
        action(nil, nil, tokenRefreshError);
    });
    return;
  }

  // access token is expired, first refresh the token, then perform action
  NSAssert(_pendingActionsSyncObject, @"_pendingActionsSyncObject cannot be nil", @"");
  OIDAuthStatePendingAction* pendingAction =
      [[OIDAuthStatePendingAction alloc] initWithAction:action andDispatchQueue:dispatchQueue];
  @synchronized(_pendingActionsSyncObject) {
    // if a token is already in the process of being refreshed, adds to pending actions
    if (_pendingActions) {
      [_pendingActions addObject:pendingAction];
      return;
    }

    // creates a list of pending actions, starting with this one
    _pendingActions = [NSMutableArray arrayWithObject:pendingAction];
  }

  // refresh the tokens
  OIDTokenRequest *tokenRefreshRequest =
      [self tokenRefreshRequestWithAdditionalParameters:additionalParameters];
  [OIDAuthorizationService performTokenRequest:tokenRefreshRequest
                 originalAuthorizationResponse:_lastAuthorizationResponse
                                      callback:^(OIDTokenResponse *_Nullable response,
                                                 NSError *_Nullable error) {
    // update OIDAuthState based on response
    if (response) {
      self->_needsTokenRefresh = NO;
      [self updateWithTokenResponse:response error:nil];
    } else {
      if (error.domain == OIDOAuthTokenErrorDomain) {
        self->_needsTokenRefresh = NO;
        [self updateWithAuthorizationError:error];
      } else {
        if ([self->_errorDelegate respondsToSelector:
            @selector(authState:didEncounterTransientError:)]) {
          [self->_errorDelegate authState:self didEncounterTransientError:error];
        }
      }
    }

    // nil the pending queue and process everything that was queued up
    NSArray *actionsToProcess;
    @synchronized(self->_pendingActionsSyncObject) {
      actionsToProcess = self->_pendingActions;
      self->_pendingActions = nil;
    }
    for (OIDAuthStatePendingAction* actionToProcess in actionsToProcess) {
      dispatch_async(actionToProcess.dispatchQueue, ^{
        actionToProcess.action(self.accessToken, self.idToken, error);
      });
    }
  }];
}

#pragma mark -

/*! @fn isTokenFresh
    @brief Determines whether a token refresh request must be made to refresh the tokens.
 */
- (BOOL)isTokenFresh {
  if (_needsTokenRefresh) {
    // forced refresh
    return NO;
  }

  if (!self.accessTokenExpirationDate) {
    // if there is no expiration time but we have an access token, it is assumed to never expire
    return !!self.accessToken;
  }

  // has the token expired?
  BOOL tokenFresh = [self.accessTokenExpirationDate timeIntervalSinceNow] > kExpiryTimeTolerance;
  return tokenFresh;
}

@end

