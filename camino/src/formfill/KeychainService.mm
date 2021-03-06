/* -*- Mode: C++; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*- */
/* ***** BEGIN LICENSE BLOCK *****
 * Version: MPL 1.1/GPL 2.0/LGPL 2.1
 *
 * The contents of this file are subject to the Mozilla Public License Version
 * 1.1 (the "License"); you may not use this file except in compliance with
 * the License. You may obtain a copy of the License at
 * http://www.mozilla.org/MPL/
 *
 * Software distributed under the License is distributed on an "AS IS" basis,
 * WITHOUT WARRANTY OF ANY KIND, either express or implied. See the License
 * for the specific language governing rights and limitations under the
 * License.
 *
 * The Original Code is mozilla.org code.
 *
 * The Initial Developer of the Original Code is
 * Netscape Communications Corporation.
 * Portions created by the Initial Developer are Copyright (C) 1998
 * the Initial Developer. All Rights Reserved.
 *
 * Contributor(s):
 *   Benoit Foucher <bfoucher@mac.com>
 *   Stuart Morgan <stuart.morgan@gmail.com>
 *
 * Alternatively, the contents of this file may be used under the terms of
 * either the GNU General Public License Version 2 or later (the "GPL"), or
 * the GNU Lesser General Public License Version 2.1 or later (the "LGPL"),
 * in which case the provisions of the GPL or the LGPL are applicable instead
 * of those above. If you wish to allow use of your version of this file only
 * under the terms of either the GPL or the LGPL, and not to allow others to
 * use your version of this file under the terms of the MPL, indicate your
 * decision by deleting the provisions above and replace them with the notice
 * and other provisions required by the GPL or the LGPL. If you do not delete
 * the provisions above, a recipient may use your version of this file under
 * the terms of any one of the MPL, the GPL or the LGPL.
 *
 * ***** END LICENSE BLOCK ***** */

// Security must be imported first, because of uint32 declaration conflicts
#import <Security/Security.h>

#import "NSString+Gecko.h"

#import "KeychainItem.h"
#import "KeychainService.h"
#import "KeychainDenyList.h"
#import "CHBrowserService.h"
#import "PreferenceManager.h"
#import "AutoCompleteUtils.h"
#import "KeyEquivView.h"
#import "nsAlertController.h"

#include "nsIPref.h"
#include "nsIObserverService.h"
#include "nsIObserver.h"
#include "nsCRT.h"
#include "nsString.h"
#include "nsNetUtil.h"
#include "nsReadableUtils.h"
#include "nsUnicharUtils.h"
#include "nsIWindowWatcher.h"
#include "nsIPrompt.h"
#include "nsIDOMWindowInternal.h"
#include "nsIDocument.h"
#include "nsIDOMHTMLDocument.h"
#include "nsIDOMHTMLCollection.h"
#include "nsIDOMNSHTMLInputElement.h"
#include "nsIDOMHTMLSelectElement.h"
#include "nsIDOMHTMLOptionElement.h"
#include "nsIDOMEvent.h"
#include "nsIDOMEventTarget.h"
#include "nsIDOMEventListener.h"
#include "nsIURL.h"
#include "nsIDOMWindowCollection.h"
#include "nsIContent.h"
#include "nsIWindowWatcher.h"
#include "nsIWebBrowserChrome.h"
#include "nsIEmbeddingSiteWindow.h"
#include "nsAppDirectoryServiceDefs.h"

#ifdef __LITTLE_ENDIAN__
static const PRUint32 kSecAuthenticationTypeHTTPDigestReversed = 'httd';
#else
static const PRUint32 kSecAuthenticationTypeHTTPDigestReversed = 'dtth';
#endif

static const OSType kCaminoKeychainCreatorCode = 'CMOZ';

static const int kDefaultHTTPSPort = 443;

// Keys for dictionaries holding login information during user prompts
static NSString* const kLoginUsernameKey = @"username";             // NSString
static NSString* const kLoginPasswordKey = @"password";             // NSString
static NSString* const kLoginHostKey = @"host";                     // NSString
static NSString* const kLoginSecurityDomainKey = @"securityDomain"; // NSString
static NSString* const kLoginPortKey = @"port";                     // NSNumber
static NSString* const kLoginSchemeKey = @"scheme";                 // NSString
static NSString* const kLoginKeychainEntry = @"kechainEntry";       // KeychainItem

// Number of seconds to keep a keychain item cached
static const int kCacheTimeout = 120;

// from CHBrowserService.h
extern NSString* const XPCOMShutDownNotificationName;

static NSWindow* GetNSWindow(nsIDOMWindow* inWindow);

@interface KeychainService(Private)
- (KeychainItem*)findLegacyKeychainEntryForHost:(NSString*)host port:(UInt16)port;
- (void)upgradeLegacyKeychainEntry:(KeychainItem*)keychainItem
                        withScheme:(NSString*)scheme
                            isForm:(BOOL)isFrom;
- (NSString*)allowedActionHostsFile;
@end

@implementation KeychainService

static KeychainService *sInstance = nil;
static const char* const gUseKeychainPref = "chimera.store_passwords_with_keychain";

int KeychainPrefChangedCallback(const char* pref, void* data);

//
// KeychainPrefChangedCallback
//
// Pref callback to tell us when the pref values for using the keychain
// have changed. We need to re-cache them at that time.
//
int KeychainPrefChangedCallback(const char* inPref, void* unused)
{
  BOOL success = NO;
  if (strcmp(inPref, gUseKeychainPref) == 0)
    [KeychainService instance]->mFormPasswordFillIsEnabled = [[PreferenceManager sharedInstance] getBooleanPref:gUseKeychainPref withSuccess:&success];
  
  return NS_OK;
}


+ (KeychainService*)instance
{
  return sInstance ? sInstance : sInstance = [[self alloc] init];
}

- (id)init
{
  if ((self = [super init])) {
    // Add a new form submit observer. We explicitly hold a ref in case the
    // observer service uses a weakref.
    nsCOMPtr<nsIObserverService> svc = do_GetService("@mozilla.org/observer-service;1");
    NS_ASSERTION(svc, "Keychain can't get observer service");
    mFormSubmitObserver = new KeychainFormSubmitObserver();
    if (mFormSubmitObserver && svc) {
      NS_ADDREF(mFormSubmitObserver);
      svc->AddObserver(mFormSubmitObserver, NS_FORMSUBMIT_SUBJECT, PR_FALSE);
    }
  
    // register for the cocoa notification posted when XPCOM shutdown so we
    // can unregister the pref callbacks we register below
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(shutdown:) name:XPCOMShutDownNotificationName
      object:nil];
    
    // cache the values of the prefs and register pref-changed callbacks. Yeah, I know
    // nsIPref is obsolete, but i'm not about to create an nsIObserver just for this.
    mFormPasswordFillIsEnabled = NO;
    nsCOMPtr<nsIPref> pref(do_GetService(NS_PREF_CONTRACTID));
    if (pref) {
      BOOL success = NO;
      mFormPasswordFillIsEnabled = [[PreferenceManager sharedInstance] getBooleanPref:gUseKeychainPref withSuccess:&success];
      pref->RegisterCallback(gUseKeychainPref, KeychainPrefChangedCallback, nsnull);
    }
    
    // load the mapping of hosts to allowed action hosts
    mAllowedActionHosts = [[NSMutableDictionary alloc] initWithContentsOfFile:[self allowedActionHostsFile]];
    if (!mAllowedActionHosts)
      mAllowedActionHosts = [[NSMutableDictionary alloc] init];

    mCachedKeychainItems = [[NSMutableDictionary alloc] init];
    mKeychainCacheTimers = [[NSMutableDictionary alloc] init];

    // load the keychain.nib file with our dialogs in it
    BOOL success;
    success = [NSBundle loadNibNamed:@"Keychain" owner:self];
    NS_ASSERTION(success, "can't load keychain prompt dialogs");
  }
  return self;
}

- (void)dealloc
{
  // unregister for shutdown notification. It may have already happened, but just in case.
  NS_IF_RELEASE(mFormSubmitObserver);
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  
  [mAllowedActionHosts release];
  [mCachedKeychainItems release];
  [mKeychainCacheTimers release];

  [super dealloc];
}

//
// shutdown:
//
// Called in response to the cocoa notification "XPCOM Shutdown" sent by the cocoa
// browser service before it terminates embedding and shuts down xpcom. Allows us
// to get rid of anything we're holding onto for the length of the app.
//
- (void)shutdown:(id)unused
{
  // unregister ourselves as listeners of prefs before prefs go away
  nsCOMPtr<nsIPref> pref(do_GetService(NS_PREF_CONTRACTID));
  if (pref)
    pref->UnregisterCallback(gUseKeychainPref, KeychainPrefChangedCallback, nsnull);
  
  [sInstance release];
}


- (BOOL)formPasswordFillIsEnabled
{
  return mFormPasswordFillIsEnabled;
}

- (KeychainItem*)findWebFormKeychainEntryForUsername:(NSString*)username
                                             forHost:(NSString*)host
                                                port:(UInt16)port
                                              scheme:(NSString*)scheme
{
  SecProtocolType protocol = [scheme isEqualToString:@"https"] ? kSecProtocolTypeHTTPS : kSecProtocolTypeHTTP;

  KeychainItem* item = [KeychainItem keychainItemForHost:host
                                                username:username
                                                    port:port
                                                protocol:protocol
                                      authenticationType:kSecAuthenticationTypeHTMLForm];

  if (item && [item password] && ![[item password] isEqualToString:@" "])
    return item;

  item = [self findLegacyKeychainEntryForHost:host port:port];
  if (item && [item password] && [[item username] isEqualToString:username])
    return item;

  return nil;
}

- (KeychainItem*)findDefaultWebFormKeychainEntryForHost:(NSString*)host
                                                   port:(UInt16)port
                                                 scheme:(NSString*)scheme
{
  NSArray* keychainItems = [self allWebFormKeychainItemsForHost:host port:port scheme:scheme];

  return [self defaultFromKeychainItems:keychainItems];
}

//
// setDefaultWebFormKeychainEntry
//
// Discussion of how the default keychain entry is chosen in Camino and Safari:
//  Safari sets its default entry by entering 'default' in the keychain entry
//  comment field.  We designed Camino so that it can use another default
//  by setting 'camino_default' in the comment field. Camino first checks for
//  'camino_default', then looks for 'default' if there isn't one.  Safari will
//  overwrite the comment field when setting the default.  If Safari changes the
//  'camino_default' entry to 'default', Camino will still treat it as the
//  default.  Camino won't overwrite a comment field, meaning that the Safari
//  default will be preserved if the user selects the same item in Camino.
//
// This method sets the default Camino keychain entry.  The default Camino
// entry will have a comment value set to "camino_default".  It first clears
// any existing default Camino entry before setting the passed in keychain to
// the new default.  It doesn't modify any other comment values, meaning that
// the Safari default will preserved.
- (void)setDefaultWebFormKeychainEntry:(KeychainItem*)keychainItem
{
  NSArray* keychainArray =  [KeychainItem allKeychainItemsForHost:[keychainItem host]
                                                             port:[keychainItem port]
                                                         protocol:[keychainItem protocol]
                                               authenticationType:[keychainItem authenticationType]
                                                          creator:0];

  NSEnumerator* keychainEnumerator = [keychainArray objectEnumerator];
  KeychainItem* keychainTemp;
  while ((keychainTemp = [keychainEnumerator nextObject])) {
    if ([[keychainTemp comment] isEqualToString:@"camino_default"])
      [keychainTemp setComment:@""];
  }

  if ([[keychainItem comment] isEqualToString:@""])
    [keychainItem setComment:@"camino_default"];
}

- (NSArray*)allWebFormKeychainItemsForHost:(NSString*)host port:(UInt16)port scheme:(NSString*)scheme
{
  SecProtocolType protocol = [scheme isEqualToString:@"https"] ? kSecProtocolTypeHTTPS : kSecProtocolTypeHTTP;

  // Since there are old-style (pre-1.1) authenticationType values, retrieve them all then filter.
  NSArray* keychainItems = [KeychainItem allKeychainItemsForHost:host
                                                            port:port
                                                        protocol:protocol
                                              authenticationType:0
                                                         creator:0];

  NSMutableArray* returnItems = [[[NSMutableArray alloc] init] autorelease];
  KeychainItem* item;
  NSEnumerator* keychainEnumerator = [keychainItems objectEnumerator];
  while ((item = [keychainEnumerator nextObject])) {
    if ([item authenticationType] == kSecAuthenticationTypeHTMLForm ||
        [item authenticationType] == kSecAuthenticationTypeHTTPDigest) {
      [returnItems addObject:item];
    }
    else if ([item authenticationType] == kSecAuthenticationTypeHTTPDigestReversed) {
      [item setAuthenticationType:kSecAuthenticationTypeHTTPDigest];
      [returnItems addObject:item];
    }
  }
  
  return returnItems;
}

//
// defaultFromKeychainItems
//
// Method that takes an array of web form keychain items and returns the default.
//
- (KeychainItem*)defaultFromKeychainItems:(NSArray*)items
{
  // First, check for the default Camino entry.
  KeychainItem* item;
  NSEnumerator* keychainEnumerator = [items objectEnumerator];
  while ((item = [keychainEnumerator nextObject])) {
    if ([[item comment] isEqualToString:@"camino_default"] && [item password])
      return item;
  }

  // Next, check for Safari's default.
  keychainEnumerator = [items objectEnumerator];
  while ((item = [keychainEnumerator nextObject])) {
    if ([[item comment] isEqualToString:@"default"]) {
      // Safari doesn't bother to set kSecNegativeItemAttr on "Passwords not saved"
      // items; that's just the way they roll. This fragile method is the best we can do.
      if ([[item password] isEqualToString:@" "])
        continue;
      if ([item password])
        return item;
    }
  }

  // Then check for the first new-style Camino keychain entry.
  keychainEnumerator = [items objectEnumerator];
  while ((item = [keychainEnumerator nextObject])) {
    if (([item creator] == kCaminoKeychainCreatorCode) && [item password])
      return item;
  }

  // Finally, just arbitrarily pick the first one.
  keychainEnumerator = [items objectEnumerator];
  while ((item = [keychainEnumerator nextObject])) {
    if ([[item password] isEqualToString:@" "])
      continue;
    if ([item password])
      return item;
  }

  return nil;
}

- (KeychainItem*)findAuthKeychainEntryForHost:(NSString*)host
                                         port:(UInt16)port
                                       scheme:(NSString*)scheme
                               securityDomain:(NSString*)securityDomain
{
  SecProtocolType protocol = [scheme isEqualToString:@"https"] ? kSecProtocolTypeHTTPS : kSecProtocolTypeHTTP;

  NSArray* newKeychainItems = [KeychainItem allKeychainItemsForHost:host
                                                               port:port
                                                           protocol:protocol
                                                 authenticationType:kSecAuthenticationTypeDefault
                                                            creator:0];

  // If we have a security domain, discard mismatched domains and re-sort the array
  // to prefer matching realms over generic items.
  // This is here rather than in allKeychainItemsForHost:... only to allow preferring
  // new-stlye Camino entries with no security domain over Safari entries. These were
  // only created in pre-1.1 nightlies, and are fixed at first use, so at some
  // point this can handled like ports in allKeychainItemsForHost:...
  if (securityDomain) {
    NSMutableArray* matchingItems = [NSMutableArray array];
    NSMutableArray* genericItems = [NSMutableArray array];
    KeychainItem* item;
    NSEnumerator* keychainEnumerator = [newKeychainItems objectEnumerator];
    while ((item = [keychainEnumerator nextObject])) {
      NSString* realm = [item securityDomain];
      if ([realm isEqualToString:@""])
        [genericItems addObject:item];
      else if ([realm isEqualToString:securityDomain])
        [matchingItems addObject:item];
    }
    newKeychainItems = [matchingItems arrayByAddingObjectsFromArray:genericItems];
  }
  
  // Find the best matching keychain entry. The password is always checked to
  // ensure that it's not nil before returning that item (which triggers an auth
  // request if necsessary) so that we know we are always returning something
  // that is actually useful.

  // First, check for a new-style Camino keychain entry
  KeychainItem* item;
  NSEnumerator* keychainEnumerator = [newKeychainItems objectEnumerator];
  while ((item = [keychainEnumerator nextObject])) {
    if (([item creator] == kCaminoKeychainCreatorCode) && [item password])
      return item;
  }

  // If there isn't one, check for an old-style Camino entry
  item = [self findLegacyKeychainEntryForHost:host port:port];
  if (item && [item password])
    return item;

  // Finally, just arbitrarily pick the first one that looks plausible.
  keychainEnumerator = [newKeychainItems objectEnumerator];
  while ((item = [keychainEnumerator nextObject])) {
    if ([[item password] isEqualToString:@" "])
      continue;
    if ([item password])
      return item;
  }

  return nil;
}

// Prior to 1.1, keychain items were stored with a different authentication type
// and may have been created with the authentication type backward due to an
// endian bug in KeychainManager. This can be removed once it's reasonable to
// assume people no longer have old-style keychain items.
- (KeychainItem*)findLegacyKeychainEntryForHost:(NSString*)host port:(UInt16)port
{
  KeychainItem* item = [KeychainItem keychainItemForHost:host
                                                username:nil
                                                    port:port
                                                protocol:kSecProtocolTypeHTTP
                                      authenticationType:kSecAuthenticationTypeHTTPDigest];
  if (!item) {
    // check for the reverse auth type
    item = [KeychainItem keychainItemForHost:host
                                    username:nil
                                        port:port
                                    protocol:kSecProtocolTypeHTTP
                          authenticationType:kSecAuthenticationTypeHTTPDigestReversed];
    // fix it for future queries
    [item setAuthenticationType:kSecAuthenticationTypeHTTPDigest];
  }
  return item;
}

- (KeychainItem*)storeUsername:(NSString*)username
                      password:(NSString*)password
                       forHost:(NSString*)host
                securityDomain:(NSString*)securityDomain
                          port:(UInt16)port
                        scheme:(NSString*)scheme
                        isForm:(BOOL)isForm
{
  SecProtocolType protocol = [scheme isEqualToString:@"https"] ? kSecProtocolTypeHTTPS : kSecProtocolTypeHTTP;
  SecAuthenticationType authType = isForm ? kSecAuthenticationTypeHTMLForm : kSecAuthenticationTypeDefault;

  KeychainItem* newItem = [KeychainItem addKeychainItemForHost:host
                                                          port:port
                                                      protocol:protocol
                                            authenticationType:authType
                                                  withUsername:username
                                                      password:password];
  [newItem setCreator:kCaminoKeychainCreatorCode];
  if (securityDomain) {
    if (isForm)
      [self setAllowedActionHosts:[NSArray arrayWithObject:securityDomain] forHost:host];
    else
      [newItem setSecurityDomain:securityDomain];
  }
  
  return newItem;
}

// Stores changes to a site's stored account. Note that this may return a different item than
// the one passed in: because we don't handle multiple accounts, we want to allow users to
// store an acccount in Camino that isn't the one we pick up from Safari. For password updates
// we update the existing item, but for username updates we make a new item if the one we were
// using wasn't Camino-created.
- (KeychainItem*)updateAuthKeychainEntry:(KeychainItem*)keychainItem
                            withUsername:(NSString*)username
                                password:(NSString*)password
{
  if ([username isEqualToString:[keychainItem username]] || [keychainItem creator] == kCaminoKeychainCreatorCode) {
    [keychainItem setUsername:username password:password];
  }
  else {
    keychainItem = [KeychainItem addKeychainItemForHost:[keychainItem host]
                                                   port:[keychainItem port]
                                               protocol:[keychainItem protocol]
                                     authenticationType:[keychainItem authenticationType]
                                           withUsername:username
                                               password:password];
    [keychainItem setCreator:kCaminoKeychainCreatorCode];
  }
  return keychainItem;
}

- (void)upgradeLegacyKeychainEntry:(KeychainItem*)keychainItem
                        withScheme:(NSString*)scheme
                            isForm:(BOOL)isForm
{
  [keychainItem setProtocol:([scheme isEqualToString:@"https"] ? kSecProtocolTypeHTTPS
                                                               : kSecProtocolTypeHTTP)];
  [keychainItem setAuthenticationType:(isForm ? kSecAuthenticationTypeHTMLForm
                                              : kSecAuthenticationTypeDefault)];
  [keychainItem setCreator:kCaminoKeychainCreatorCode];
}

// Removes all Camino-created keychain entries. This will only remove new-style entries,
// because it's not safe to assume that all passwords that match the old format were
// necessarily created by us.
- (void)removeAllUsernamesAndPasswords
{
  NSArray* keychainItems = [KeychainItem allKeychainItemsForHost:nil
                                                            port:kAnyPort
                                                        protocol:0
                                              authenticationType:0
                                                         creator:kCaminoKeychainCreatorCode];
  KeychainItem* item;
  NSEnumerator* keychainEnumerator = [keychainItems objectEnumerator];
  while ((item = [keychainEnumerator nextObject])) {
    [item removeFromKeychain];
  }
  // Clear the parallel storage of action hosts
  [mAllowedActionHosts removeAllObjects];
  [mAllowedActionHosts writeToFile:[self allowedActionHostsFile] atomically:YES];

  // Reset the deny list as well
  [[KeychainDenyList instance] removeAllHosts];
}

//
// addListenerToView:
//
// Add a listener to the view to auto fill username and passwords
// fields if the values are stored in the Keychain.
//
- (void)addListenerToView:(CHBrowserView*)view
{
  [view addListener:[[[KeychainBrowserListener alloc] initWithBrowser:view] autorelease]];
}

//
// hitButtonOK:
// hitButtonCancel:
// hitButtonOther:
//
// actions for the buttons of the keychain prompt dialogs.
//

- (IBAction)hitButtonOK:(id)sender
{
  [NSApp stopModalWithCode:NSAlertDefaultReturn];
}

- (IBAction)hitButtonCancel:(id)sender
{
  [NSApp stopModalWithCode:NSAlertAlternateReturn];
}

- (IBAction)hitButtonOther:(id)sender
{
  [NSApp stopModalWithCode:NSAlertOtherReturn];
}

//
// promptToStoreLogin:inWindow:
//
// Puts up a dialog when the keychain doesn't yet have an entry from
// this site asking to store it, forget it this once, or mark the site
// on a deny list so we never ask again.
//
- (void)promptToStoreLogin:(NSDictionary*)loginInfo inWindow:(NSWindow*)window
{
  // Retain the context info across to the sheet callback (where it is released)
  [loginInfo retain];

  NSAlert* alert = [[[NSAlert alloc] init] autorelease];
  [alert setMessageText:NSLocalizedString(@"KeychainStoreAlertTitle", nil)];
  [alert setInformativeText:NSLocalizedString(@"KeychainStoreAlertText", nil)];

  [alert addButtonWithTitle:NSLocalizedString(@"KeychainStoreAlertStoreButton", nil)];

  NSButton* dontStore = [alert addButtonWithTitle:NSLocalizedString(@"KeychainStoreAlertDontStoreButton", nil)];
  [dontStore setKeyEquivalent:@"\e"];  // Esc
  [dontStore setKeyEquivalentModifierMask:0];

  KeyEquivView* dontStoreEquiv = [KeyEquivView kevWithKeyEquivalent:@"d"
                                          keyEquivalentModifierMask:NSCommandKeyMask
                                                             target:dontStore
                                                             action:@selector(performClick:)];
  [[[alert window] contentView] addSubview:dontStoreEquiv];

  NSButton* neverStore = [alert addButtonWithTitle:NSLocalizedString(@"KeychainStoreAlertNeverStoreButton", nil)];
  [neverStore setKeyEquivalent:@"n"];
  [neverStore setKeyEquivalentModifierMask:NSCommandKeyMask];

  if ([dontStore canBecomeKeyView])
    [[alert window] makeFirstResponder:dontStore];
  [alert beginSheetModalForWindow:window
                    modalDelegate:self
                   didEndSelector:@selector(storeSheetDidEnd:returnCode:contextInfo:)
                      contextInfo:(void*)loginInfo];
}

- (void)storeSheetDidEnd:(NSAlert*)sheet
              returnCode:(int)returnCode
             contextInfo:(void*)contextInfo
{
  NSDictionary* loginInfo = (NSDictionary*)contextInfo;
  switch (returnCode) {
    case NSAlertFirstButtonReturn: {  // Save
        KeychainItem* keychainEntry =
          [self storeUsername:[loginInfo objectForKey:kLoginUsernameKey]
                     password:[loginInfo objectForKey:kLoginPasswordKey]
                      forHost:[loginInfo objectForKey:kLoginHostKey]
               securityDomain:[loginInfo objectForKey:kLoginSecurityDomainKey]
                         port:[[loginInfo objectForKey:kLoginPortKey] intValue]
                       scheme:[loginInfo objectForKey:kLoginSchemeKey]
                       isForm:YES];
        [self setDefaultWebFormKeychainEntry:keychainEntry];
      }

      break;
      
    case NSAlertSecondButtonReturn: // Don't remember
      // do nothing at all
      break;
      
    case NSAlertThirdButtonReturn:  // Never remember
      [self addHostToDenyList:[loginInfo objectForKey:kLoginHostKey]];
      break;
  }
  [loginInfo release]; // balance the retain in the alert creation
}

//
// confirmChangePassword:
//
// The password stored in the keychain differs from what the user typed
// in. Ask what they want to do to resolve the issue.
//
- (void)promptToUpdateKeychainItem:(KeychainItem*)keychainItem
                      withUsername:(NSString*)username
                          password:(NSString*)password
                          inWindow:(NSWindow*)window
{
  // Retain the context info across to the sheet callback (where it is released)
  NSDictionary* contextInfo = [NSDictionary dictionaryWithObjectsAndKeys:
        username, kLoginUsernameKey,
        password, kLoginPasswordKey,
    keychainItem, kLoginKeychainEntry,
                  nil];
  [contextInfo retain];
  
  NSAlert* alert = [[[NSAlert alloc] init] autorelease];
  [alert setMessageText:NSLocalizedString(@"KeychainUpdateAlertTitle", nil)];
  [alert setInformativeText:NSLocalizedString(@"KeychainUpdateAlertText", nil)];

  [alert addButtonWithTitle:NSLocalizedString(@"KeychainUpdateAlertUpdateButton", nil)];

  NSButton* dontUpdate = [alert addButtonWithTitle:NSLocalizedString(@"KeychainUpdateAlertDontUpdateButton", nil)];
  [dontUpdate setKeyEquivalent:@"\e"];  // Esc
  [dontUpdate setKeyEquivalentModifierMask:0];

  [alert beginSheetModalForWindow:window
                    modalDelegate:self
                   didEndSelector:@selector(updateSheetDidEnd:returnCode:contextInfo:)
                      contextInfo:(void*)contextInfo];
}

- (void)updateSheetDidEnd:(NSAlert*)sheet
               returnCode:(int)returnCode
              contextInfo:(void*)contextInfo
{
  NSDictionary* loginInfo = (NSDictionary*)contextInfo;
  if (returnCode == NSAlertFirstButtonReturn) {
    KeychainItem* keychainItem = [loginInfo objectForKey:kLoginKeychainEntry];
    [keychainItem setUsername:[loginInfo objectForKey:kLoginUsernameKey]
                     password:[loginInfo objectForKey:kLoginPasswordKey]];
  }
  [loginInfo release]; // balance the retain in the alert creation
}

//
// confirmFillPassword:
//
// The password stored in the keychain has an action domain that
// doesn't match the stored value; ask the user whether to fill.
//
- (BOOL)confirmFillPassword:(NSWindow*)parent
{
  int result = [nsAlertController safeRunModalForWindow:mConfirmFillPasswordPanel
                                       relativeToWindow:parent];
  [mConfirmFillPasswordPanel close];
  // Default is not to fill
  return (result != NSAlertDefaultReturn);
}


- (void)addHostToDenyList:(NSString*)host
{
  [[KeychainDenyList instance] addHost:host];
}

- (BOOL)isHostInDenyList:(NSString*)host
{
  return [[KeychainDenyList instance] isHostPresent:host];
}

// Ideally, these would be stored in the keychain item itself, but there is no
// attribute where we can store arbitrary data (and using the security domain
// make us incompatible with Safari), so we keep a parallel list.
// TODO: If keychain item is deleted, we'll don't know to clean up the corresponding
// entry here. Eventually we need a strategy to prevent cruft from accumulating.
- (void)setAllowedActionHosts:(NSArray*)actionHosts forHost:(NSString*)host
{
  [mAllowedActionHosts setValue:actionHosts forKey:host];
  [mAllowedActionHosts writeToFile:[self allowedActionHostsFile] atomically:YES];
}

- (NSArray*)allowedActionHostsForHost:(NSString*)host
{
  return [mAllowedActionHosts objectForKey:host];
}

- (NSString*)allowedActionHostsFile
{
  NSString* profilePath = [[PreferenceManager sharedInstance] profilePath];
  return [profilePath stringByAppendingPathComponent:@"AllowedActionHosts.plist"];
}

// To prevent two lookups for every keychain use (once to fill, and another to
// compare against on submit), we cache each keychain entry for a little while.
// This ensures that we update the same entry we filled with, as well as
// preventing multiple auth dialogs if the user chooses "allow once" the first
// time.
//
// Call with |nil| for |keychainItem| to clear a cached entry.
- (void)cacheKeychainEntry:(KeychainItem*)keychainItem forKey:(NSString*)key {
  if (!key)
    return;

  if (keychainItem) {
    // If there was already an invalidation timer running for a previously
    // cached keychain entry for this host, invalidate it so that the new
    // cached entry will last the full duration.
    [[mKeychainCacheTimers objectForKey:key] invalidate];
    [mCachedKeychainItems setObject:keychainItem forKey:key];
    NSTimer* invalidationTimer = [NSTimer scheduledTimerWithTimeInterval:kCacheTimeout
                                                                  target:self
                                                                selector:@selector(expirationTimerFired:)
                                                                userInfo:(id)key
                                                                 repeats:NO];
    [mKeychainCacheTimers setObject:invalidationTimer forKey:key];
  }
  else {
    [[mKeychainCacheTimers objectForKey:key] invalidate];
    [mKeychainCacheTimers removeObjectForKey:key];
    [mCachedKeychainItems removeObjectForKey:key];
  }
}

- (KeychainItem*)cachedKeychainEntryForKey:(NSString*)key {
  return [[[mCachedKeychainItems objectForKey:key] retain] autorelease];
}

- (void)expirationTimerFired:(NSTimer*)theTimer {
  // Ensure that the key will survive past the timer invalidation
  NSString* key = [[[theTimer userInfo] retain] autorelease];
  [self cacheKeychainEntry:nil forKey:key];
}

@end


//
// Keychain prompt implementation.
//
NS_IMPL_ISUPPORTS2(KeychainPrompt,
                   nsIAuthPrompt,
                   nsIAuthPromptWrapper)

KeychainPrompt::KeychainPrompt()
{
}

KeychainPrompt::~KeychainPrompt()
{
  // NSLog(@"Keychain prompt died.");
}


//
// TODO: add support for ftp username/password.
//
// Get server name and port from the realm ("hostname:port (realm)",
// see nsHttpChannel.cpp). we can't use CFURL routines or nsIURI
// routines because they require a protocol, and we don't have one.
//
// The given realm for an ftp server has the form ftp://<username>@<server>/<path>, see
// netwerk/protocol/ftp/src/nsFtpConnectionThread.cpp).
//
void
KeychainPrompt::ExtractRealmComponents(NSString* inRealmBlob, NSString** outHost, NSString** outRealm, UInt16* outPort)
{
  if (!outHost || !outPort)
    return;
  *outHost = nil;
  *outRealm = nil;
  *outPort = kAnyPort;

  // first check for an ftp url and pull out the server from the realm
  if ([inRealmBlob rangeOfString:@"ftp://"].location != NSNotFound) {
    // cut out ftp://
    inRealmBlob = [inRealmBlob substringFromIndex:strlen("ftp://")];
    
    // cut out any of the path
    NSRange pathDelimeter = [inRealmBlob rangeOfString:@"/"];
    if (pathDelimeter.location != NSNotFound)
      inRealmBlob = [inRealmBlob substringToIndex:(pathDelimeter.location - 1)];
    
    // now we're left with "username@server" with username being optional
    NSRange usernameMarker = [inRealmBlob rangeOfString:@"@"];
    if (usernameMarker.location != NSNotFound)
      *outHost = [inRealmBlob substringFromIndex:(usernameMarker.location + 1)];
    else
      *outHost = inRealmBlob;
  }
  else { // it's an http realm
    // pull off the " (realm)" part
    NSRange openParen = [inRealmBlob rangeOfString:@"("];
    if (openParen.location != NSNotFound) {
      NSRange closeParen = [inRealmBlob rangeOfString:@")"];
      if (closeParen.location != NSNotFound) {
        NSRange realmRange = NSMakeRange(openParen.location + 1, closeParen.location - openParen.location - 1);
        *outRealm = [inRealmBlob substringWithRange:realmRange];
      }
      inRealmBlob = [inRealmBlob substringToIndex:openParen.location - 1];
    }
    
    // separate the host and the port
    NSRange endOfHost = [inRealmBlob rangeOfString:@":"];
    if (endOfHost.location == NSNotFound)
      *outHost = inRealmBlob;
    else {
      *outHost = [inRealmBlob substringToIndex:endOfHost.location];
      *outPort = [[inRealmBlob substringFromIndex:(endOfHost.location + 1)] intValue];
    }
  }
}

void
KeychainPrompt::PreFill(const PRUnichar *realmBlob, PRUnichar **user, PRUnichar **pwd)
{
  NSString* host = nil;
  NSString* realm = nil;
  UInt16 port = kAnyPort;
  NSString* realmBlobString = [NSString stringWithPRUnichars:realmBlob];
  ExtractRealmComponents(realmBlobString, &host, &realm, &port);

  // Pre-fill user/password if found in the keychain.
  // We don't get scheme information from gecko, so guess based on the port
  NSString* scheme = (port == kDefaultHTTPSPort) ? @"https" : @"http";

  KeychainService* keychain = [KeychainService instance];
  KeychainItem* entry = [keychain findAuthKeychainEntryForHost:host
                                                          port:port
                                                        scheme:scheme
                                                securityDomain:realm];
  if (entry) {
    [keychain cacheKeychainEntry:entry forKey:realmBlobString];
    if (user)
      *user = [[entry username] createNewUnicodeBuffer];
    if (pwd)
      *pwd = [[entry password] createNewUnicodeBuffer];
  }
}

void
KeychainPrompt::ProcessPrompt(const PRUnichar* realmBlob, bool checked, PRUnichar* user, PRUnichar *pwd)
{
  NSString* host = nil;
  NSString* realm = nil;
  UInt16 port = kAnyPort;
  NSString* realmBlobString = [NSString stringWithPRUnichars:realmBlob];
  ExtractRealmComponents(realmBlobString, &host, &realm, &port);

  NSString* username = [NSString stringWithPRUnichars:user];
  NSString* password = [NSString stringWithPRUnichars:pwd];

  // We don't get scheme information from gecko, so guess based on the port
  NSString* scheme = (port == kDefaultHTTPSPort) ? @"https" : @"http";

  // Check the cache first, then fall back to a search in case a cached
  // entry expired before the user submitted.
  KeychainService* keychain = [KeychainService instance];
  KeychainItem* keychainEntry = [keychain cachedKeychainEntryForKey:realmBlobString];
  if (!keychainEntry) {
    keychainEntry = [keychain findAuthKeychainEntryForHost:host
                                                      port:port
                                                    scheme:scheme
                                            securityDomain:realm];
  }

  // Update, store or remove the user/password depending on the user
  // choice and whether or not we found the username/password in the
  // keychain.
  if (checked) {
    if (!keychainEntry) {
      [keychain storeUsername:username
                     password:password
                      forHost:host
               securityDomain:realm
                         port:port
                       scheme:scheme
                       isForm:NO];
    }
    else {
      // If it's an old-style entry, upgrade it now that we know what it goes with.
      if ([keychainEntry authenticationType] == kSecAuthenticationTypeHTTPDigest)
        [keychain upgradeLegacyKeychainEntry:keychainEntry withScheme:scheme isForm:NO];

      if (![[keychainEntry username] isEqualToString:username] ||
          ![[keychainEntry password] isEqualToString:password])
      {
        keychainEntry = [keychain updateAuthKeychainEntry:keychainEntry
                                             withUsername:username
                                                 password:password];
      }
    }
  }
  else if (keychainEntry) {
    [keychainEntry removeFromKeychain];
  }
  // We are done with the entry, so remove it from the cache.
  [keychain cacheKeychainEntry:nil forKey:realmBlobString];
}

//
// Implementation of nsIAuthPrompt
//
NS_IMETHODIMP
KeychainPrompt::Prompt(const PRUnichar *dialogTitle,
                        const PRUnichar *text,
                        const PRUnichar *passwordRealm,
                        PRUint32 savePassword,
                        const PRUnichar *defaultText,
                        PRUnichar **result,
                        PRBool *_retval)
{
  if (defaultText)
    *result = ToNewUnicode(nsDependentString(defaultText));

  mPrompt->Prompt(dialogTitle, text, result, nsnull, nsnull, _retval);

  return NS_OK;
}

NS_IMETHODIMP
KeychainPrompt::PromptUsernameAndPassword(const PRUnichar *dialogTitle,
                                            const PRUnichar *text,
                                            const PRUnichar *realmBlob,
                                            PRUint32 savePassword,
                                            PRUnichar **user,
                                            PRUnichar **pwd,
                                            PRBool *_retval)
{
  PreFill(realmBlob, user, pwd);

  PRBool checked = (pwd != NULL && *pwd != NULL);
  PRUnichar* checkTitle = [NSLocalizedString(@"KeychainCheckTitle", @"") createNewUnicodeBuffer];

  nsresult rv = mPrompt->PromptUsernameAndPassword(dialogTitle, text, user, pwd, checkTitle, &checked, _retval);
  if (checkTitle)
    nsMemory::Free(checkTitle);
  if (NS_FAILED(rv))
    return rv;
  
  if(*_retval)
    ProcessPrompt(realmBlob, checked, *user, *pwd);

  return NS_OK;
}

NS_IMETHODIMP
KeychainPrompt::PromptPassword(const PRUnichar *dialogTitle,
                                const PRUnichar *text,
                                const PRUnichar *realmBlob,
                                PRUint32 savePassword,
                                PRUnichar **pwd,
                                PRBool *_retval)
{
  PreFill(realmBlob, nsnull, pwd);

  PRBool checked = (pwd != NULL && *pwd != NULL);
  PRUnichar* checkTitle = [NSLocalizedString(@"KeychainCheckTitle", @"") createNewUnicodeBuffer];

  nsresult rv = mPrompt->PromptPassword(dialogTitle, text, pwd, checkTitle, &checked, _retval);
  if (checkTitle)
    nsMemory::Free(checkTitle);
  if (NS_FAILED(rv))
    return rv;
  
  if(*_retval)
    ProcessPrompt(realmBlob, checked, nsnull, *pwd);

  return NS_OK;
}

NS_IMETHODIMP
KeychainPrompt::SetPromptDialogs(nsIPrompt* dialogs)
{
  mPrompt = dialogs;
  return NS_OK;
}

//
// Keychain form submit observer implementation.
//
NS_IMPL_ISUPPORTS2(KeychainFormSubmitObserver,
                   nsIObserver,
                   nsIFormSubmitObserver)

KeychainFormSubmitObserver::KeychainFormSubmitObserver()
{
  //NSLog(@"Keychain form submit observer created.");
}

KeychainFormSubmitObserver::~KeychainFormSubmitObserver()
{
  //NSLog(@"Keychain form submit observer died.");
}

NS_IMETHODIMP
KeychainFormSubmitObserver::Observe(nsISupports *aSubject, const char *aTopic, const PRUnichar *someData)
{
  return NS_OK;
}

NS_IMETHODIMP
KeychainFormSubmitObserver::Notify(nsIDOMHTMLFormElement* formNode, nsIDOMWindowInternal* window, nsIURI* actionURL,
                                    PRBool* cancelSubmit)
{
  KeychainService* keychain = [KeychainService instance];
  if (![keychain formPasswordFillIsEnabled])
    return NS_OK;

  nsCOMPtr<nsIContent> node(do_QueryInterface(formNode));
  if (!formNode)
    return NS_OK;

  // seek out the username and password fields. If there are two password fields, we don't
  // want to do anything since it's probably not a signin form. Passing PR_FALSE in the last
  // param will cause FUPF to look for multiple password fields and then bail if that is the
  // case, seting |passwordElement| to nsnull.
  nsCOMPtr<nsIDOMHTMLInputElement> usernameElement, passwordElement;
  nsresult rv = FindUsernamePasswordFields(formNode, getter_AddRefs(usernameElement), getter_AddRefs(passwordElement),
                                           PR_FALSE);

  if (NS_SUCCEEDED(rv) && usernameElement && passwordElement) {
    // extract username and password from the fields
    nsAutoString uname, pword;
    usernameElement->GetValue(uname);
    passwordElement->GetValue(pword);
    NSString* username = [NSString stringWith_nsAString:uname];
    NSString* password = [NSString stringWith_nsAString:pword];
    if (![username length] || ![password length])      // bail if either is empty
      return NS_OK;

    nsCOMPtr<nsIDocument> doc = node->GetDocument();
    if (!doc)
      return NS_OK;

    nsIURI* docURL = doc->GetDocumentURI();
    if (!docURL)
      return NS_OK;
    nsCAutoString uriCAString;
    rv = docURL->GetSpec(uriCAString);
    NSString* uri = [NSString stringWithCString:uriCAString.get()];

    nsCAutoString hostCAString;
    docURL->GetHost(hostCAString);
    NSString* host = [NSString stringWithCString:hostCAString.get()];

    // is the host in the deny list? if yes, bail. otherwise check the keychain.
    if ([keychain isHostInDenyList:host])
      return NS_OK;

    // Get the host in punycode for keychain use.
    nsCAutoString asciiHostCAString;
    rv = docURL->GetAsciiHost(asciiHostCAString);
    NSString* asciiHost = NS_SUCCEEDED(rv) ? [NSString stringWithCString:asciiHostCAString.get()]
                                           : host;

    nsCAutoString schemeCAString;
    docURL->GetScheme(schemeCAString);
    NSString* scheme = [NSString stringWithCString:schemeCAString.get()];

    PRInt32 signedPort;
    docURL->GetPort(&signedPort);
    UInt16 port = (signedPort < 0) ? kAnyPort : (UInt16)signedPort;

    nsAutoString action;
    formNode->GetAction(action);
    NSString* actionHost = [[NSURL URLWithString:[NSString stringWith_nsAString:action]] host];
    // Forms without an action specified submit to the page
    if (!actionHost)
      actionHost = host;

    // Search for an existing keychain entry with the same username.
    // Check the cache first, then fall back to a search in case a cached
    // entry expired before the user submitted.
    KeychainItem* keychainEntry = [keychain cachedKeychainEntryForKey:uri];
    // We weren't using punycode for keychain entries up through 1.5, so try
    // non-punycode first to favor Camino entries.
    if (!keychainEntry || ![[keychainEntry username] isEqualToString:username]) {
      keychainEntry = [keychain findWebFormKeychainEntryForUsername:username
                                                            forHost:host
                                                               port:port
                                                             scheme:scheme];
    }
    if (![asciiHost isEqualToString:host]) {
      if (keychainEntry) {
        if ([[keychainEntry host] isEqualToString:host])
          [keychainEntry setHost:asciiHost];
      }
      else {
        keychainEntry = [keychain findWebFormKeychainEntryForUsername:username
                                                              forHost:asciiHost
                                                                 port:port
                                                               scheme:scheme];
      }
    }
    // If there's already an entry in the keychain for the username, check if the
    // password matches. If not, ask the user what they want to do and replace
    // it as necessary. If there's no entry for this username, ask if they want to
    // remember it and then put it into the keychain
    if (keychainEntry) {
      // If it's an old-style entry, upgrade it now that we know what it goes with.
      if ([keychainEntry authenticationType] == kSecAuthenticationTypeHTTPDigest)
        [keychain upgradeLegacyKeychainEntry:keychainEntry withScheme:scheme isForm:YES];

      if (![[keychainEntry password] isEqualToString:password]) {
        [keychain promptToUpdateKeychainItem:keychainEntry
                                withUsername:username
                                    password:password
                                    inWindow:GetNSWindow(window)];
      }

      [keychain setDefaultWebFormKeychainEntry:keychainEntry];

      if ([[keychain allowedActionHostsForHost:host] count] == 0)
        [keychain setAllowedActionHosts:[NSArray arrayWithObject:actionHost] forHost:host];
      // We don't need to look up the entry again, so remove it from the cache.
      [keychain cacheKeychainEntry:nil forKey:uri];
    }
    else {
      NSDictionary* loginInfo = [NSDictionary dictionaryWithObjectsAndKeys:
                             username, kLoginUsernameKey,
                             password, kLoginPasswordKey,
                            asciiHost, kLoginHostKey,
                           actionHost, kLoginSecurityDomainKey,
        [NSNumber numberWithInt:port], kLoginPortKey,
                               scheme, kLoginSchemeKey,
                                       nil];
      [keychain promptToStoreLogin:loginInfo inWindow:GetNSWindow(window)];
    }
  }

  return NS_OK;
}


@implementation KeychainBrowserListener

- (id)initWithBrowser:(CHBrowserView*)aBrowser
{
  if ((self = [super init])) {
    mBrowserView = aBrowser;
  }
  return self;
}

- (void)dealloc
{
  // NSLog(@"Keychain browser listener died.");
  [super dealloc];
}

//
// -fillDOMWindow:
//
// Given a dom window (the root of a page, frame, or iframe), fill in the username
// and password if there are appropriate fields in any frame within this "window". Once
// it's done, it recurses over all of the subframes and fills them in as well.
//
- (void)fillDOMWindow:(nsIDOMWindow*)inDOMWindow
{
  KeychainService* keychain = [KeychainService instance];
  if(![keychain formPasswordFillIsEnabled])
    return;

  nsCOMPtr<nsIDOMDocument> domDoc;
  inDOMWindow->GetDocument(getter_AddRefs(domDoc));
  nsCOMPtr<nsIDocument> doc (do_QueryInterface(domDoc));
  if (!doc) {
    NS_ASSERTION(0, "no document available");
    return;
  }
  
  nsIURI* docURL = doc->GetDocumentURI();
  if (!docURL)
    return;

  nsCOMPtr<nsIDOMHTMLDocument> htmldoc(do_QueryInterface(doc));
  if (!htmldoc)
    return;

  nsCOMPtr<nsIDOMHTMLCollection> forms;
  nsresult rv = htmldoc->GetForms(getter_AddRefs(forms));
  if (NS_FAILED(rv) || !forms)
    return;

  NSString* uri = nil;
  NSString* host = nil;
  KeychainItem* keychainEntry = nil;
  BOOL silentlyDenySuspiciousForms = NO;

  //
  // Seek out username and password element in all forms. If found in
  // a form, check the keychain to see if the username password are
  // stored and prefill the elements.
  //
  PRUint32 numForms;
  forms->GetLength(&numForms);
  for (PRUint32 formX = 0; formX < numForms; formX++) {
    nsCOMPtr<nsIDOMNode> formNode;
    rv = forms->Item(formX, getter_AddRefs(formNode));
    if (NS_FAILED(rv) || formNode == nsnull)
      continue;

    // search the current form for the text fields
    nsCOMPtr<nsIDOMHTMLFormElement> formElement(do_QueryInterface(formNode));
    if (!formElement)
      continue;
    nsCOMPtr<nsIDOMHTMLInputElement> usernameElement, passwordElement;
    rv = FindUsernamePasswordFields(formElement, getter_AddRefs(usernameElement), getter_AddRefs(passwordElement),
                                    PR_TRUE);

    if (!(NS_SUCCEEDED(rv) && usernameElement && passwordElement))
      continue;

    // We found a login form; if it's the first one we've seen, check the
    // keychain for a saved password.
    if (!keychainEntry) {
      nsCAutoString hostCAString;
      docURL->GetHost(hostCAString);
      host = [NSString stringWithCString:hostCAString.get()];
      nsCAutoString asciiHostCAString;
      docURL->GetAsciiHost(asciiHostCAString);
      NSString* asciiHost = NS_SUCCEEDED(rv) ? [NSString stringWithCString:asciiHostCAString.get()]
                                             : host;
      nsCAutoString schemeCAString;
      docURL->GetScheme(schemeCAString);
      NSString* scheme = [NSString stringWithCString:schemeCAString.get()];

      PRInt32 signedPort;
      docURL->GetPort(&signedPort);
      UInt16 port = (signedPort < 0) ? kAnyPort : (UInt16)signedPort;

      // We weren't using punycode for keychain entries up through 1.5, so try
      // non-punycode first to favor Camino entries.
      keychainEntry = [keychain findDefaultWebFormKeychainEntryForHost:host
                                                                  port:port
                                                                scheme:scheme];
      if (![asciiHost isEqualToString:host]) {
        if (keychainEntry) {
          [keychainEntry setHost:asciiHost];
        }
        else {
          keychainEntry = [keychain findDefaultWebFormKeychainEntryForHost:asciiHost
                                                                      port:port
                                                                    scheme:scheme];
        }
      }
    }
    // If we don't have a password for the page, don't bother looking for
    // more forms.
    if (!keychainEntry)
      break;

    // To help prevent password stealing on sites that allow user-created HTML (but not JS),
    // only fill if the form's action host is one that has been authorized by the user.
    // If the site doesn't have any authorized hosts, either because it pre-dates
    // this code or because it's a non-Camino entry we haven't used before, fill any form.
    nsAutoString action;
    formElement->GetAction(action);
    NSString* actionHost = [[NSURL URLWithString:[NSString stringWith_nsAString:action]] host];
    if (!actionHost)
      actionHost = host;
    NSArray* allowedActionHosts = [keychain allowedActionHostsForHost:host];
    if ([allowedActionHosts count] > 0 && ![allowedActionHosts containsObject:actionHost]) {
      // The form has an un-authorized action domain. If we haven't
      // asked the user about this page, ask. If we have and they said
      // no, don't ask (to prevent a malicious page from throwing
      // dialogs until the user tries the other button).
      if (silentlyDenySuspiciousForms)
        continue;
      if (![keychain confirmFillPassword:GetNSWindow(inDOMWindow)]) {
        silentlyDenySuspiciousForms = YES;
        continue;
      }
      // Remember the approval
      [keychain setAllowedActionHosts:[allowedActionHosts arrayByAddingObject:actionHost] forHost:host];
    }

    nsAutoString user, pwd;
    [[keychainEntry username] assignTo_nsAString:user];
    [[keychainEntry password] assignTo_nsAString:pwd];

    // If the server specifies a value attribute, only autofill the password if
    // what we have in keychain matches what the server supplies (bug 169760).
    nsAutoString userValue;
    usernameElement->GetValue(userValue);
    if (!userValue.Length() || userValue.Equals(user, nsCaseInsensitiveStringComparator())) {
      rv = usernameElement->SetValue(user);
      rv = passwordElement->SetValue(pwd);
    }

    // Now that we have actually filled the password, cache the keychain entry.
    if (!uri) {
      nsCAutoString uriCAString;
      rv = docURL->GetSpec(uriCAString);
      uri = [NSString stringWithCString:uriCAString.get()];
    }
    [keychain cacheKeychainEntry:keychainEntry forKey:uri];
  } // for each form on page

  // recursively check sub-frames and iframes
  nsCOMPtr<nsIDOMWindowCollection> frames;
  inDOMWindow->GetFrames(getter_AddRefs(frames));
  if (frames) {
    PRUint32 numFrames;
    frames->GetLength(&numFrames);
    for (PRUint32 i = 0; i < numFrames; i++) {
      nsCOMPtr<nsIDOMWindow> frameNode;
      frames->Item(i, getter_AddRefs(frameNode));
      if (frameNode)
        [self fillDOMWindow:frameNode];
    }
  }
}

- (void)onLoadingCompleted:(BOOL)succeeded;
{
  if(!succeeded)
    return;
  
  // prime the pump with the top dom window.
  nsCOMPtr<nsIDOMWindow> domWin = [mBrowserView contentWindow];
  if (!domWin)
    return;
  
  // recursively fill frames and iFrames.
  [self fillDOMWindow:domWin];
}

- (void)onLoadingStarted
{
}

- (void)onResourceLoadingStarted:(NSValue*)resourceIdentifier
{
}

- (void)onResourceLoadingCompleted:(NSValue*)resourceIdentifier
{
}

- (void)onProgressChange:(long)currentBytes outOf:(long)maxBytes
{
}

- (void)onProgressChange64:(long long)currentBytes outOf:(long long)maxBytes
{
}

- (void)onLocationChange:(NSString*)urlSpec isNewPage:(BOOL)newPage requestSucceeded:(BOOL)requestOK
{
}

- (void)onStatusChange:(NSString*)aMessage
{
}

- (void)onSecurityStateChange:(unsigned long)newState
{
}

- (void)onShowContextMenu:(int)flags domEvent:(nsIDOMEvent*)aEvent domNode:(nsIDOMNode*)aNode
{
}

- (void)onShowTooltip:(NSPoint)where withText:(NSString*)text
{
}

- (void)onHideTooltip
{
}

- (void)onPopupBlocked:(nsIDOMPopupBlockedEvent*)data;
{
}

- (void)onFoundShortcutIcon:(NSString*)inIconURI
{
}

- (void)onFeedDetected:(NSString*)inFeedURI feedTitle:(NSString*)inFeedTitle;
{
}

- (void)onSearchPluginDetected:(NSURL*)pluginURL mimeType:(NSString*)pluginMIMEType displayName:(NSString*)pluginName
{
}

- (void)onXULCommand:(nsIDOMNSEvent*)aDOMEvent
{
}

@end

//
// GetNSWindow
//
// Finds the native window for the given DOM window
//
NSWindow* GetNSWindow(nsIDOMWindow* inWindow)
{
  CHBrowserView* browserView = [CHBrowserView browserViewFromDOMWindow:inWindow];
  return [browserView nativeWindow];
}

//
// FindUsernamePasswordFields
//
// Searches the form for the first username and password fields. If
// none are found, the out params will be nsnull. |inStopWhenFound|
// determines how we proceed once we find things. When true, we bail
// as soon as we find both a username and password field. If false, we
// continue searching the form for a 2nd password field (such as in a
// "change your password" form). If we find one, null out
// |outPassword| since we probably don't want to prefill this form.
//
nsresult FindUsernamePasswordFields(nsIDOMHTMLFormElement* inFormElement,
                                    nsIDOMHTMLInputElement** outUsername,
                                    nsIDOMHTMLInputElement** outPassword,
                                    PRBool inStopWhenFound)
{
  if (!outUsername || !outPassword)
    return NS_ERROR_FAILURE;
  *outUsername = *outPassword = nsnull;

  PRBool autoCompleteOverride = [[PreferenceManager sharedInstance] getBooleanPref:kGeckoPrefIgnoreAutocompleteOff
                                                                       withSuccess:NULL];

  // pages can specify that they don't want autofill by setting a
  // "autocomplete=off" attribute on the form.
  nsAutoString autocomplete;
  inFormElement->GetAttribute(NS_LITERAL_STRING("autocomplete"), autocomplete);
  if (autocomplete.EqualsIgnoreCase("off") && !autoCompleteOverride)
    return NS_ERROR_FAILURE;
  
  //
  // Search the form the password field and the preceding text field
  // We are only interested in signon forms, so we require
  // only one password in the form. If there's more than one password
  // it's probably a form to setup the password or to change the
  // password. We don't want to handle this kind of form at this
  // point.
  //
  nsCOMPtr<nsIDOMHTMLCollection> elements;
  nsresult rv = inFormElement->GetElements(getter_AddRefs(elements));
  if (NS_FAILED(rv) || !elements)
    return NS_ERROR_FAILURE;

  PRUint32 numElements;
  elements->GetLength(&numElements);

  for (PRUint32 elementX = 0; elementX < numElements; elementX++) {

    nsCOMPtr<nsIDOMNode> elementNode;
    rv = elements->Item(elementX, getter_AddRefs(elementNode));
    if (NS_FAILED(rv) || !elementNode)
      continue;

    nsCOMPtr<nsIDOMHTMLInputElement> inputElement(do_QueryInterface(elementNode));
    if (!inputElement)
      continue;

    nsAutoString type;
    rv = inputElement->GetType(type);
    if (NS_FAILED(rv))
      continue;

    PRBool isDisabled = PR_FALSE;
    rv = inputElement->HasAttribute(NS_LITERAL_STRING("disabled"), &isDisabled);
    if (NS_FAILED(rv) || isDisabled)
      continue;

    bool isText = (type.IsEmpty() || type.Equals(NS_LITERAL_STRING("text"), nsCaseInsensitiveStringComparator()));
    bool isPassword = type.Equals(NS_LITERAL_STRING("password"), nsCaseInsensitiveStringComparator());
    inputElement->GetAttribute(NS_LITERAL_STRING("autocomplete"), autocomplete);

    if ((!isText && !isPassword) || (autocomplete.EqualsIgnoreCase("off") && !autoCompleteOverride))
      continue;

    //
    // If there's a second password in the form, it's probably not a
    // signin form, probably a form to setup or change
    // passwords. Stop here and ensure we don't store this password.
    //
    if (!inStopWhenFound && isPassword && *outPassword) {
      NS_RELEASE(*outPassword);
      *outPassword = nsnull;
      return NS_ERROR_FAILURE;
    }
    
    // Keep taking text fields until we have a password, so that
    // username is the field before password.
    if(isText && !*outPassword) {
      if (*outUsername) NS_RELEASE(*outUsername);
      *outUsername = inputElement;
      NS_ADDREF(*outUsername);
    }
    else if (isPassword && !*outPassword) {
      *outPassword = inputElement;
      NS_ADDREF(*outPassword);
    }
    
    // we've got everything we need, we're done.
    if (inStopWhenFound && *outPassword && *outUsername)
      return NS_OK;
    
  } // for each item in form

  return (*outPassword && *outUsername) ? NS_OK : NS_ERROR_FAILURE;
}
