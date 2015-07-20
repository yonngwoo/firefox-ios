/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Account
import ReadingList
import Shared
import Storage
import Sync
import XCGLogger

// TODO: same comment as for SyncAuthState.swift!
private let log = XCGLogger.defaultInstance()

public protocol SyncManager {
    func syncClients() -> SyncResult
    func syncClientsThenTabs() -> SyncResult
    func syncHistory() -> SyncResult
    func syncLogins() -> SyncResult

    // The simplest possible approach.
    func beginTimedSyncs()
    func endTimedSyncs()

    func onRemovedAccount(account: FirefoxAccount?) -> Success
    func onAddedAccount() -> Success
}

typealias EngineIdentifier = String
typealias SyncFunction = (SyncDelegate, Prefs, Ready) -> SyncResult

class ProfileFileAccessor: FileAccessor {
    init(profile: Profile) {
        let profileDirName = "profile.\(profile.localName())"

        // Bug 1147262: First option is for device, second is for simulator.
        var rootPath: String?
        if let sharedContainerIdentifier = ExtensionUtils.sharedContainerIdentifier(), url = NSFileManager.defaultManager().containerURLForSecurityApplicationGroupIdentifier(sharedContainerIdentifier), path = url.path {
            rootPath = path
        } else {
            log.error("Unable to find the shared container. Defaulting profile location to ~/Documents instead.")
            rootPath = String(NSSearchPathForDirectoriesInDomains(.DocumentDirectory, .UserDomainMask, true)[0] as! NSString)
        }

        super.init(rootPath: rootPath!.stringByAppendingPathComponent(profileDirName))
    }
}

class CommandDiscardingSyncDelegate: SyncDelegate {
    func displaySentTabForURL(URL: NSURL, title: String) {
        // TODO: do something else.
        log.info("Discarding sent URL \(URL.absoluteString)")
    }
}

/**
 * This exists because the Sync code is extension-safe, and thus doesn't get
 * direct access to UIApplication.sharedApplication, which it would need to
 * display a notification.
 * This will also likely be the extension point for wipes, resets, and
 * getting access to data sources during a sync.
 */

let TabSendURLKey = "TabSendURL"
let TabSendTitleKey = "TabSendTitle"
let TabSendCategory = "TabSendCategory"

enum SentTabAction: String {
    case View = "TabSendViewAction"
    case Bookmark = "TabSendBookmarkAction"
    case ReadingList = "TabSendReadingListAction"
}

class BrowserProfileSyncDelegate: SyncDelegate {
    let app: UIApplication

    init(app: UIApplication) {
        self.app = app
    }

    // SyncDelegate
    func displaySentTabForURL(URL: NSURL, title: String) {
        // check to see what the current notification settings are and only try and send a notification if
        // the user has agreed to them
        let currentSettings = app.currentUserNotificationSettings()
        if currentSettings.types.rawValue & UIUserNotificationType.Alert.rawValue != 0 {
            log.info("Displaying notification for URL \(URL.absoluteString)")

            let notification = UILocalNotification()
            notification.fireDate = NSDate()
            notification.timeZone = NSTimeZone.defaultTimeZone()
            notification.alertBody = String(format: NSLocalizedString("New tab: %@: %@", comment:"New tab [title] [url]"), title, URL.absoluteString!)
            notification.userInfo = [TabSendURLKey: URL.absoluteString!, TabSendTitleKey: title]
            notification.alertAction = nil
            notification.category = TabSendCategory

            app.presentLocalNotificationNow(notification)
        }
    }
}

/**
 * A Profile manages access to the user's data.
 */
protocol Profile {
    var bookmarks: protocol<BookmarksModelFactory, ShareToDestination> { get }
    // var favicons: Favicons { get }
    var prefs: Prefs { get }
    var queue: TabQueue { get }
    var searchEngines: SearchEngines { get }
    var files: FileAccessor { get }
    var history: protocol<BrowserHistory, SyncableHistory> { get }
    var favicons: Favicons { get }
    var readingList: ReadingListService? { get }
    var logins: protocol<BrowserLogins, SyncableLogins> { get }
    var thumbnails: Thumbnails { get }

    func shutdown()

    // I got really weird EXC_BAD_ACCESS errors on a non-null reference when I made this a getter.
    // Similar to <http://stackoverflow.com/questions/26029317/exc-bad-access-when-indirectly-accessing-inherited-member-in-swift>.
    func localName() -> String

    // URLs and account configuration.
    var accountConfiguration: FirefoxAccountConfiguration { get }

    func getAccount() -> FirefoxAccount?
    func removeAccount()
    func setAccount(account: FirefoxAccount)

    func getClients() -> Deferred<Result<[RemoteClient]>>
    func getClientsAndTabs() -> Deferred<Result<[ClientAndTabs]>>
    func getCachedClientsAndTabs() -> Deferred<Result<[ClientAndTabs]>>

    func storeTabs(tabs: [RemoteTab]) -> Deferred<Result<Int>>

    func sendItems(items: [ShareItem], toClients clients: [RemoteClient])

    var syncManager: SyncManager { get }
}

public class BrowserProfile: Profile {
    private let name: String
    weak private var app: UIApplication?

    init(localName: String, app: UIApplication?) {
        self.name = localName
        self.app = app

        let notificationCenter = NSNotificationCenter.defaultCenter()
        let mainQueue = NSOperationQueue.mainQueue()
        notificationCenter.addObserver(self, selector: Selector("onLocationChange:"), name: "LocationChange", object: nil)

        if let baseBundleIdentifier = ExtensionUtils.baseBundleIdentifier() {
            KeychainWrapper.serviceName = baseBundleIdentifier
        } else {
            log.error("Unable to get the base bundle identifier. Keychain data will not be shared.")
        }

        // If the profile dir doesn't exist yet, this is first run (for this profile).
        if !files.exists("") {
            log.info("New profile. Removing old account data.")
            removeAccount()
            prefs.clearAll()
        }
    }

    // Extensions don't have a UIApplication.
    convenience init(localName: String) {
        self.init(localName: localName, app: nil)
    }

    func shutdown() {
        if dbCreated {
            db.close()
        }

        if loginsDBCreated {
            loginsDB.close()
        }
    }

    @objc
    func onLocationChange(notification: NSNotification) {
        if let v = notification.userInfo!["visitType"] as? Int,
           let visitType = VisitType(rawValue: v),
           let url = notification.userInfo!["url"] as? NSURL,
           let title = notification.userInfo!["title"] as? NSString {

            // We don't record a visit if no type was specified -- that means "ignore me".
            let site = Site(url: url.absoluteString!, title: title as String)
            let visit = SiteVisit(site: site, date: NSDate.nowMicroseconds(), type: visitType)
            log.debug("Recording visit for \(url) with type \(v).")
            history.addLocalVisit(visit)
        } else {
            let url = notification.userInfo!["url"] as? NSURL
            log.debug("Ignoring navigation for \(url).")
        }
    }

    deinit {
        self.syncManager.endTimedSyncs()
        NSNotificationCenter.defaultCenter().removeObserver(self)
    }

    func localName() -> String {
        return name
    }

    var files: FileAccessor {
        return ProfileFileAccessor(profile: self)
    }

    lazy var queue: TabQueue = {
        return SQLiteQueue(db: self.db)
    }()

    private var dbCreated = false
    lazy var db: BrowserDB = {
        self.dbCreated = true
        return BrowserDB(filename: "browser.db", files: self.files)
    }()


    /**
     * Favicons, history, and bookmarks are all stored in one intermeshed
     * collection of tables.
     */
    private lazy var places: protocol<BrowserHistory, Favicons, SyncableHistory> = {
        return SQLiteHistory(db: self.db)
    }()

    var favicons: Favicons {
        return self.places
    }

    var history: protocol<BrowserHistory, SyncableHistory> {
        return self.places
    }

    lazy var bookmarks: protocol<BookmarksModelFactory, ShareToDestination> = {
        return SQLiteBookmarks(db: self.db)
    }()

    lazy var searchEngines: SearchEngines = {
        return SearchEngines(prefs: self.prefs)
    }()

    func makePrefs() -> Prefs {
        return NSUserDefaultsPrefs(prefix: self.localName())
    }

    lazy var prefs: Prefs = {
        return self.makePrefs()
    }()

    lazy var readingList: ReadingListService? = {
        return ReadingListService(profileStoragePath: self.files.rootPath)
    }()

    private lazy var remoteClientsAndTabs: RemoteClientsAndTabs = {
        return SQLiteRemoteClientsAndTabs(db: self.db)
    }()

    lazy var syncManager: SyncManager = {
        return BrowserSyncManager(profile: self)
    }()

    private func getSyncDelegate() -> SyncDelegate {
        if let app = self.app {
            return BrowserProfileSyncDelegate(app: app)
        }
        return CommandDiscardingSyncDelegate()
    }

    public func getClients() -> Deferred<Result<[RemoteClient]>> {
        return self.syncManager.syncClients()
           >>> { self.remoteClientsAndTabs.getClients() }
    }

    public func getClientsAndTabs() -> Deferred<Result<[ClientAndTabs]>> {
        return self.syncManager.syncClientsThenTabs()
           >>> { self.remoteClientsAndTabs.getClientsAndTabs() }
    }

    public func getCachedClientsAndTabs() -> Deferred<Result<[ClientAndTabs]>> {
        return self.remoteClientsAndTabs.getClientsAndTabs()
    }

    func storeTabs(tabs: [RemoteTab]) -> Deferred<Result<Int>> {
        return self.remoteClientsAndTabs.insertOrUpdateTabs(tabs)
    }

    public func sendItems(items: [ShareItem], toClients clients: [RemoteClient]) {
        let commands = items.map { item in
            SyncCommand.fromShareItem(item, withAction: "displayURI")
        }
        self.remoteClientsAndTabs.insertCommands(commands, forClients: clients)
    }

    lazy var logins: protocol<BrowserLogins, SyncableLogins> = {
        return SQLiteLogins(db: self.loginsDB)
    }()

    private lazy var loginsKey: String? = {
        let key = "sqlcipher.key.logins.db"
        if KeychainWrapper.hasValueForKey(key) {
            return KeychainWrapper.stringForKey(key)
        }

        let Length: UInt = 256
        let secret = Bytes.generateRandomBytes(Length).base64EncodedString
        KeychainWrapper.setString(secret, forKey: key)
        return secret
    }()

    private var loginsDBCreated = false
    private lazy var loginsDB: BrowserDB = {
        self.loginsDBCreated = true
        return BrowserDB(filename: "logins.db", secretKey: self.loginsKey, files: self.files)
    }()

    lazy var thumbnails: Thumbnails = {
        return SDWebThumbnails(files: self.files)
    }()

    let accountConfiguration: FirefoxAccountConfiguration = ProductionFirefoxAccountConfiguration()

    private lazy var account: FirefoxAccount? = {
        if let dictionary = KeychainWrapper.objectForKey(self.name + ".account") as? [String: AnyObject] {
            return FirefoxAccount.fromDictionary(dictionary)
        }
        return nil
    }()

    func getAccount() -> FirefoxAccount? {
        return account
    }

    func removeAccount() {
        let old = self.account

        prefs.removeObjectForKey(PrefsKeys.KeyLastRemoteTabSyncTime)
        KeychainWrapper.removeObjectForKey(name + ".account")
        self.account = nil

        // tell any observers that our account has changed
        NSNotificationCenter.defaultCenter().postNotificationName(NotificationFirefoxAccountChanged, object: nil)

        // Trigger cleanup. Pass in the account in case we want to try to remove
        // client-specific data from the server.
        self.syncManager.onRemovedAccount(old)

        // deregister for remote notifications
        app?.unregisterForRemoteNotifications()
    }

    func setAccount(account: FirefoxAccount) {
        KeychainWrapper.setObject(account.asDictionary(), forKey: name + ".account")
        self.account = account

        // register for notifications for the account
        registerForNotifications()
        
        // tell any observers that our account has changed
        NSNotificationCenter.defaultCenter().postNotificationName(NotificationFirefoxAccountChanged, object: nil)

        self.syncManager.onAddedAccount()
    }

    func registerForNotifications() {
        let viewAction = UIMutableUserNotificationAction()
        viewAction.identifier = SentTabAction.View.rawValue
        viewAction.title = NSLocalizedString("View", comment: "View a URL - https://bugzilla.mozilla.org/attachment.cgi?id=8624438, https://bug1157303.bugzilla.mozilla.org/attachment.cgi?id=8624440")
        viewAction.activationMode = UIUserNotificationActivationMode.Foreground
        viewAction.destructive = false
        viewAction.authenticationRequired = false

        let bookmarkAction = UIMutableUserNotificationAction()
        bookmarkAction.identifier = SentTabAction.Bookmark.rawValue
        bookmarkAction.title = NSLocalizedString("Bookmark", comment: "Bookmark a URL - https://bugzilla.mozilla.org/attachment.cgi?id=8624438, https://bug1157303.bugzilla.mozilla.org/attachment.cgi?id=8624440")
        bookmarkAction.activationMode = UIUserNotificationActivationMode.Foreground
        bookmarkAction.destructive = false
        bookmarkAction.authenticationRequired = false

        let readingListAction = UIMutableUserNotificationAction()
        readingListAction.identifier = SentTabAction.ReadingList.rawValue
        readingListAction.title = NSLocalizedString("Add to Reading List", comment: "Add URL to the reading list - https://bugzilla.mozilla.org/attachment.cgi?id=8624438, https://bug1157303.bugzilla.mozilla.org/attachment.cgi?id=8624440")
        readingListAction.activationMode = UIUserNotificationActivationMode.Foreground
        readingListAction.destructive = false
        readingListAction.authenticationRequired = false

        let sentTabsCategory = UIMutableUserNotificationCategory()
        sentTabsCategory.identifier = TabSendCategory
        sentTabsCategory.setActions([readingListAction, bookmarkAction, viewAction], forContext: UIUserNotificationActionContext.Default)

        sentTabsCategory.setActions([bookmarkAction, viewAction], forContext: UIUserNotificationActionContext.Minimal)

        app?.registerUserNotificationSettings(UIUserNotificationSettings(forTypes: UIUserNotificationType.Alert, categories: [sentTabsCategory]))
        app?.registerForRemoteNotifications()
    }

    // Extends NSObject so we can use timers.
    class BrowserSyncManager: NSObject, SyncManager {
        unowned private let profile: BrowserProfile
        let FifteenMinutes = NSTimeInterval(60 * 15)
        let OneMinute = NSTimeInterval(60)

        private var syncTimer: NSTimer? = nil

        /**
         * Locking is managed by withSyncInputs. Make sure you take and release these
         * whenever you do anything Sync-ey.
         */
        var syncLock = OSSpinLock()

        private func beginSyncing() -> Bool {
            return OSSpinLockTry(&syncLock)
        }

        private func endSyncing() {
            return OSSpinLockUnlock(&syncLock)
        }

        init(profile: BrowserProfile) {
            self.profile = profile
            super.init()

            let center = NSNotificationCenter.defaultCenter()
            center.addObserver(self, selector: "onLoginDidChange:", name: NotificationDataLoginDidChange, object: nil)
        }

        deinit {
            // Remove 'em all.
            NSNotificationCenter.defaultCenter().removeObserver(self)
        }

        // Simple in-memory rate limiting.
        var lastTriggeredLoginSync: Timestamp = 0
        @objc func onLoginDidChange(notification: NSNotification) {
            log.debug("Login did change.")
            if (NSDate.now() - lastTriggeredLoginSync) > OneMinuteInMilliseconds {
                lastTriggeredLoginSync = NSDate.now()

                // Give it a few seconds.
                let when: dispatch_time_t = dispatch_time(DISPATCH_TIME_NOW, SyncConstants.SyncDelayTriggered)

                // Trigger on the main queue. The bulk of the sync work runs in the background.
                dispatch_after(when, dispatch_get_main_queue()) {
                    self.syncLogins()
                }
            }
        }

        var prefsForSync: Prefs {
            return self.profile.prefs.branch("sync")
        }

        func onAddedAccount() -> Success {
            return self.syncEverything()
        }

        func onRemovedAccount(account: FirefoxAccount?) -> Success {
            let h: SyncableHistory = self.profile.history
            let flagHistory = h.onRemovedAccount()
            let clearTabs = self.profile.remoteClientsAndTabs.onRemovedAccount()
            let done = allSucceed(flagHistory, clearTabs)

            // Clear prefs after we're done clearing everything else -- just in case
            // one of them needs the prefs and we race. Clear regardless of success
            // or failure.
            done.upon { result in
                // This will remove keys from the Keychain if they exist, as well
                // as wiping the Sync prefs.
                SyncStateMachine.clearStateFromPrefs(self.prefsForSync)
            }
            return done
        }

        private func repeatingTimerAtInterval(interval: NSTimeInterval, selector: Selector) -> NSTimer {
            return NSTimer.scheduledTimerWithTimeInterval(interval, target: self, selector: selector, userInfo: nil, repeats: true)
        }

        func beginTimedSyncs() {
            if self.syncTimer != nil {
                log.debug("Already running sync timer.")
                return
            }

            let interval = FifteenMinutes
            let selector = Selector("syncOnTimer")
            log.debug("Starting sync timer.")
            self.syncTimer = repeatingTimerAtInterval(interval, selector: selector)
        }

        /**
         * The caller is responsible for calling this on the same thread on which it called
         * beginTimedSyncs.
         */
        func endTimedSyncs() {
            if let t = self.syncTimer {
                log.debug("Stopping history sync timer.")
                self.syncTimer = nil
                t.invalidate()
            }
        }

        private func syncClientsWithDelegate(delegate: SyncDelegate, prefs: Prefs, ready: Ready) -> SyncResult {
            log.debug("Syncing clients to storage.")
            let clientSynchronizer = ready.synchronizer(ClientsSynchronizer.self, delegate: delegate, prefs: prefs)
            return clientSynchronizer.synchronizeLocalClients(self.profile.remoteClientsAndTabs, withServer: ready.client, info: ready.info)
        }

        private func syncTabsWithDelegate(delegate: SyncDelegate, prefs: Prefs, ready: Ready) -> SyncResult {
            let storage = self.profile.remoteClientsAndTabs
            let tabSynchronizer = ready.synchronizer(TabsSynchronizer.self, delegate: delegate, prefs: prefs)
            return tabSynchronizer.synchronizeLocalTabs(storage, withServer: ready.client, info: ready.info)
        }

        private func syncHistoryWithDelegate(delegate: SyncDelegate, prefs: Prefs, ready: Ready) -> SyncResult {
            log.debug("Syncing history to storage.")
            let historySynchronizer = ready.synchronizer(HistorySynchronizer.self, delegate: delegate, prefs: prefs)
            return historySynchronizer.synchronizeLocalHistory(self.profile.history, withServer: ready.client, info: ready.info)
        }

        private func syncLoginsWithDelegate(delegate: SyncDelegate, prefs: Prefs, ready: Ready) -> SyncResult {
            log.debug("Syncing logins to storage.")
            let loginsSynchronizer = ready.synchronizer(LoginsSynchronizer.self, delegate: delegate, prefs: prefs)
            return loginsSynchronizer.synchronizeLocalLogins(self.profile.logins, withServer: ready.client, info: ready.info)
        }

        /**
         * Returns nil if there's no account.
         */
        private func withSyncInputs<T>(label: EngineIdentifier? = nil, function: (SyncDelegate, Prefs, Ready) -> Deferred<Result<T>>) -> Deferred<Result<T>>? {
            if let account = profile.account {
                if !beginSyncing() {
                    log.info("Not syncing \(label); already syncing something.")
                    return deferResult(AlreadySyncingError())
                }

                if let label = label {
                    log.info("Syncing \(label).")
                }

                let authState = account.syncAuthState
                let syncPrefs = profile.prefs.branch("sync")

                let readyDeferred = SyncStateMachine.toReady(authState, prefs: syncPrefs)
                let delegate = profile.getSyncDelegate()

                let go = readyDeferred >>== { ready in
                    function(delegate, syncPrefs, ready)
                }

                // Always unlock when we're done.
                go.upon({ res in self.endSyncing() })

                return go
            }

            log.warning("No account; can't sync.")
            return nil
        }

        /**
         * Runs the single provided synchronization function and returns its status.
         */
        private func sync(label: EngineIdentifier, function: (SyncDelegate, Prefs, Ready) -> SyncResult) -> SyncResult {
            return self.withSyncInputs(label: label, function: function) ??
                   deferResult(.NotStarted(.NoAccount))
        }

        /**
         * Runs each of the provided synchronization functions with the same inputs.
         * Returns an array of IDs and SyncStatuses the same length as the input.
         */
        private func syncSeveral(synchronizers: (EngineIdentifier, SyncFunction)...) -> Deferred<Result<[(EngineIdentifier, SyncStatus)]>> {
            typealias Pair = (EngineIdentifier, SyncStatus)
            let combined: (SyncDelegate, Prefs, Ready) -> Deferred<Result<[Pair]>> = { delegate, syncPrefs, ready in
                let thunks = synchronizers.map { (i, f) in
                    return { () -> Deferred<Result<Pair>> in
                        log.debug("Syncing \(i)…")
                        return f(delegate, syncPrefs, ready) >>== { deferResult((i, $0)) }
                    }
                }
                return accumulate(thunks)
            }

            return self.withSyncInputs(label: nil, function: combined) ??
                   deferResult(synchronizers.map { ($0.0, .NotStarted(.NoAccount)) })
        }

        func syncEverything() -> Success {
            return self.syncSeveral(
                ("clients", self.syncClientsWithDelegate),
                ("tabs", self.syncTabsWithDelegate),
                ("history", self.syncHistoryWithDelegate)
            ) >>> succeed
        }


        @objc func syncOnTimer() {
            log.debug("Running timed logins sync.")

            // Note that we use .upon here rather than chaining with >>> precisely
            // to allow us to sync subsequent engines regardless of earlier failures.
            // We don't fork them in parallel because we want to limit perf impact
            // due to background syncs, and because we're cautious about correctness.
            self.syncLogins().upon { result in
                if let success = result.successValue {
                    log.debug("Timed logins sync succeeded. Status: \(success.description).")
                } else {
                    let reason = result.failureValue?.description ?? "none"
                    log.debug("Timed logins sync failed. Reason: \(reason).")
                }

                log.debug("Running timed history sync.")
                self.syncHistory().upon { result in
                    if let success = result.successValue {
                        log.debug("Timed history sync succeeded. Status: \(success.description).")
                    } else {
                        let reason = result.failureValue?.description ?? "none"
                        log.debug("Timed history sync failed. Reason: \(reason).")
                    }
                }
            }
        }

        func syncClients() -> SyncResult {
            // TODO: recognize .NotStarted.
            return self.sync("clients", function: syncClientsWithDelegate)
        }

        func syncClientsThenTabs() -> SyncResult {
            return self.syncSeveral(
                ("clients", self.syncClientsWithDelegate),
                ("tabs", self.syncTabsWithDelegate)
            ) >>== { statuses in
                let tabsStatus = statuses[1].1
                return deferResult(tabsStatus)
            }
        }

        func syncLogins() -> SyncResult {
            return self.sync("logins", function: syncLoginsWithDelegate)
        }

        func syncHistory() -> SyncResult {
            // TODO: recognize .NotStarted.
            return self.sync("history", function: syncHistoryWithDelegate)
        }
    }
}

class AlreadySyncingError: ErrorType {
    var description: String {
        return "Already syncing."
    }
}
