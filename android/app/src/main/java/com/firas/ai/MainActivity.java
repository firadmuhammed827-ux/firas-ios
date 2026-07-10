package com.firas.ai;

import android.os.Bundle;
import android.view.View;
import androidx.core.graphics.Insets;
import androidx.core.view.ViewCompat;
import androidx.core.view.WindowCompat;
import androidx.core.view.WindowInsetsCompat;
import androidx.core.view.OnApplyWindowInsetsListener;
import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {
    private String lastVarsJs = null;

    @Override
    public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState); // super first, or the Capacitor bridge won't init
        WindowCompat.setDecorFitsSystemWindows(getWindow(), false); // WebView draws behind the system bars

        // Publish the real status-bar / navigation-bar / cutout / keyboard insets to the remote page
        // as CSS vars. Android's env(safe-area-inset-*) reports 0 for these, so the site can't read them.
        ViewCompat.setOnApplyWindowInsetsListener(getWindow().getDecorView(),
            new OnApplyWindowInsetsListener() {
                @Override
                public WindowInsetsCompat onApplyWindowInsets(View v, WindowInsetsCompat insets) {
                    Insets bars = insets.getInsets(
                        WindowInsetsCompat.Type.systemBars()
                        | WindowInsetsCompat.Type.displayCutout()); // union so a landscape notch is covered
                    Insets ime = insets.getInsets(WindowInsetsCompat.Type.ime());
                    float d = getResources().getDisplayMetrics().density; // device px -> CSS px
                    int top    = Math.round(bars.top / d);
                    int right  = Math.round(bars.right / d);
                    int bottom = Math.round(bars.bottom / d);
                    int left   = Math.round(bars.left / d);
                    int kb     = Math.round(Math.max(0, ime.bottom - bars.bottom) / d);
                    String js =
                        "try{var s=document.documentElement.style;" +
                        "s.setProperty('--safe-top','" + top + "px');" +
                        "s.setProperty('--safe-right','" + right + "px');" +
                        "s.setProperty('--safe-bottom','" + bottom + "px');" +
                        "s.setProperty('--safe-left','" + left + "px');" +
                        "s.setProperty('--kb-inset','" + kb + "px');}catch(e){}";
                    if (!js.equals(lastVarsJs) && bridge != null && bridge.getWebView() != null) {
                        lastVarsJs = js; // dedupe: skip the bridge round-trip when nothing changed
                        final String toRun = js;
                        bridge.getWebView().post(new Runnable() {
                            @Override public void run() {
                                bridge.getWebView().evaluateJavascript(toRun, null);
                            }
                        });
                    }
                    return insets; // leave the insets unconsumed
                }
            });
    }
}
