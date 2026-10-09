# The agent calls into the bridge by name from JavaScript, so the annotated
# methods and the class holding them cannot be renamed or stripped.
-keepclassmembers class com.saisamardh.cliqx.bridge.AgentBridge {
    @android.webkit.JavascriptInterface <methods>;
}
