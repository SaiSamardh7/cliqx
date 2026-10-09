package com.saisamardh.cliqx.blocking

import android.net.Uri
import android.util.Log
import java.util.concurrent.atomic.AtomicInteger
import org.json.JSONArray

/**
 * Matches the WebKit content-rule format the iOS app already ships.
 *
 * Reading `blocklist.json` unchanged means the curated list has one
 * representation in the repository rather than an Android-shaped copy that
 * drifts. The subset honoured here is the subset that file uses: `url-filter`,
 * `url-filter-is-case-sensitive`, `if-domain`/`unless-domain`, a `third-party`
 * load-type, and `block` versus `ignore-previous-rules` actions.
 *
 * Not a replacement for the 183k-rule set. WebKit compiles those to a DFA; a
 * list of [Regex] walked per request would not hold up, which is the whole
 * reason [RuleEngine] is an interface. What this does prove is the plumbing:
 * that interception sees the requests, computes third-party correctly, and
 * blocks.
 */
class ContentRuleEngine private constructor(
    private val rules: List<CompiledRule>,
) : RuleEngine {

    private val blocked = AtomicInteger(0)

    override val blockedCount: Int get() = blocked.get()

    private class CompiledRule(
        val pattern: Regex,
        val thirdPartyOnly: Boolean,
        val ifDomains: List<String>,
        val unlessDomains: List<String>,
        val blocks: Boolean,
    )

    override fun shouldBlock(url: String, documentHost: String?): Boolean {
        // Later rules win, matching WebKit's ordering: an
        // `ignore-previous-rules` entry after a block must be able to undo it.
        var verdict = false
        val requestHost = hostOf(url)
        val thirdParty = isThirdParty(requestHost, documentHost)

        for (rule in rules) {
            if (rule.thirdPartyOnly && !thirdParty) continue
            if (rule.ifDomains.isNotEmpty() &&
                !rule.ifDomains.any { documentHost.matchesDomain(it) }
            ) {
                continue
            }
            if (rule.unlessDomains.any { documentHost.matchesDomain(it) }) continue
            if (!rule.pattern.containsMatchIn(url)) continue
            verdict = rule.blocks
        }

        if (verdict) blocked.incrementAndGet()
        return verdict
    }

    private fun String?.matchesDomain(candidate: String): Boolean {
        val host = this ?: return false
        // WebKit's `*domain.com` form covers subdomains; a bare domain is exact.
        return if (candidate.startsWith("*")) {
            val bare = candidate.removePrefix("*").removePrefix(".")
            host == bare || host.endsWith(".$bare")
        } else {
            host == candidate
        }
    }

    companion object {
        private const val TAG = "CliqxRules"

        /**
         * Third-party is registrable-domain comparison, not host equality:
         * `cdn.example.com` serving `example.com` is first-party. The iOS app
         * resolves this against the Public Suffix List it bundles
         * (`ios/Sources/CleanPlayer/Resources/public_suffix_list.dat.txt`).
         *
         * This uses last-two-labels, which is wrong for `co.uk` and every other
         * multi-label suffix — it would call `bbc.co.uk` and `itv.co.uk`
         * first-party to each other. Acceptable only because the skeleton's
         * list is domain-anchored third-party ad hosts where the comparison
         * does not arise. Porting the PSL lookup is required before this engine
         * meets any real list; see android/README.md.
         */
        fun isThirdParty(requestHost: String?, documentHost: String?): Boolean {
            if (requestHost == null || documentHost == null) return false
            return registrableDomain(requestHost) != registrableDomain(documentHost)
        }

        private fun registrableDomain(host: String): String {
            val labels = host.split('.')
            return if (labels.size <= 2) host else labels.takeLast(2).joinToString(".")
        }

        private fun hostOf(url: String): String? =
            try {
                Uri.parse(url).host
            } catch (_: Exception) {
                null
            }

        /** Parses the WebKit content-rule JSON, skipping entries it cannot use. */
        fun from(json: String): ContentRuleEngine {
            val compiled = mutableListOf<CompiledRule>()
            val array = try {
                JSONArray(json)
            } catch (error: Exception) {
                Log.w(TAG, "Unparseable rule list: ${error.message}")
                return ContentRuleEngine(emptyList())
            }

            for (position in 0 until array.length()) {
                val entry = array.optJSONObject(position) ?: continue
                val trigger = entry.optJSONObject("trigger") ?: continue
                val action = entry.optJSONObject("action") ?: continue

                val blocks = when (action.optString("type")) {
                    "block" -> true
                    "ignore-previous-rules" -> false
                    // css-display-none is the agent's job, not the network's.
                    else -> continue
                }

                val filter = trigger.optString("url-filter").takeIf { it.isNotEmpty() }
                    ?: continue
                val options = if (trigger.optBoolean("url-filter-is-case-sensitive")) {
                    emptySet()
                } else {
                    setOf(RegexOption.IGNORE_CASE)
                }

                val pattern = try {
                    Regex(filter, options)
                } catch (error: Exception) {
                    // WebKit's dialect is narrower than java.util.regex, so a
                    // rule that will not compile here is skipped rather than
                    // taking the whole list down.
                    Log.w(TAG, "Skipped rule $position: ${error.message}")
                    continue
                }

                compiled += CompiledRule(
                    pattern = pattern,
                    thirdPartyOnly = trigger.optJSONArray("load-type")
                        ?.let { types ->
                            (0 until types.length()).any {
                                types.optString(it) == "third-party"
                            }
                        } ?: false,
                    ifDomains = trigger.stringList("if-domain"),
                    unlessDomains = trigger.stringList("unless-domain"),
                    blocks = blocks,
                )
            }

            Log.i(TAG, "Compiled ${compiled.size} of ${array.length()} rules")
            return ContentRuleEngine(compiled)
        }

        private fun org.json.JSONObject.stringList(field: String): List<String> {
            val array = optJSONArray(field) ?: return emptyList()
            return (0 until array.length()).mapNotNull {
                array.optString(it).takeIf(String::isNotEmpty)
            }
        }
    }
}
