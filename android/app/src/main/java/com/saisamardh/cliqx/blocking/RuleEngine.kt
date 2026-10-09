package com.saisamardh.cliqx.blocking

/**
 * Decides whether a subresource request may proceed.
 *
 * Android WebView has no equivalent of `WKContentRuleList` — there is no
 * content-blocking API at any API level — so blocking happens per request in
 * `shouldInterceptRequest`, on a background thread, in the hot path of every
 * page load. That makes the matcher's cost the app's cost, which is why this is
 * an interface: the skeleton ships [ContentRuleEngine], matching the curated
 * `blocklist.json` the iOS app already carries, and the full 183,732-rule set
 * arrives behind the same call by binding Brave's `adblock-rust` over JNI.
 * adblock-rust consumes ABP text directly, which is what `tools/filter-convert`
 * already starts from, so the source lists stay shared too.
 */
interface RuleEngine {

    /**
     * @param url the subresource being requested
     * @param documentHost host of the page making the request, for third-party
     *   determination; null when the host is unknown, which is treated as
     *   first-party so an unknown document cannot make everything third-party
     *   and over-block.
     */
    fun shouldBlock(url: String, documentHost: String?): Boolean

    /** Requests blocked since launch, for the badge the agent's count feeds. */
    val blockedCount: Int
}
