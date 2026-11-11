package io.github.jonniewigley.learndesk;

import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

/**
 * LearnDesk for Android: a thin shell around the phone web app in docs/, loaded from
 * GitHub Pages. The web app's service worker keeps it available offline after the first
 * launch, and its data lives in this app's own WebView storage.
 */
public class MainActivity extends Activity {
    private static final String HOST = "jonniewigley.github.io";
    private static final String PATH = "/LearnDesk/";
    private static final String APP_URL = "https://" + HOST + PATH;

    private WebView web;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        web = new WebView(this);
        web.setBackgroundColor(getColor(R.color.app_background));
        setContentView(web);

        WebSettings settings = web.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true); // the app keeps its data in localStorage
        settings.setAllowFileAccess(false);
        settings.setAllowContentAccess(false);

        web.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                Uri uri = request.getUrl();
                boolean ours = "https".equals(uri.getScheme()) && HOST.equals(uri.getHost())
                        && uri.getPath() != null && uri.getPath().startsWith(PATH);
                if (ours) return false;
                // Anything that isn't the app itself opens in the browser, never in here.
                try {
                    startActivity(new Intent(Intent.ACTION_VIEW, uri));
                } catch (ActivityNotFoundException ignored) {
                    // Nothing can open it; stay where we are.
                }
                return true;
            }

            @Override
            public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
                if (!request.isForMainFrame()) return;
                // Only reached before the app has ever loaded; after that it works offline.
                String page = "<!doctype html><meta name=viewport content='width=device-width,initial-scale=1'>"
                        + "<body style='font:16px system-ui;padding:48px 24px;text-align:center'>"
                        + "<h2>LearnDesk needs a connection the first time</h2>"
                        + "<p>Connect to the internet, then try again. After that it works offline.</p>"
                        + "<p><a href='" + APP_URL + "'>Try again</a></p>";
                view.loadDataWithBaseURL(APP_URL, page, "text/html", "utf-8", null);
            }
        });

        if (savedInstanceState == null || web.restoreState(savedInstanceState) == null) {
            web.loadUrl(APP_URL);
        }
    }

    @Override
    protected void onSaveInstanceState(Bundle outState) {
        super.onSaveInstanceState(outState);
        web.saveState(outState);
    }

    @Override
    public void onBackPressed() {
        if (web.canGoBack()) web.goBack();
        else super.onBackPressed();
    }
}
