defmodule SymphonyElixirWeb.Layouts do
  @moduledoc """
  Shared layouts for the observability dashboard.
  """

  use Phoenix.Component

  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    assigns = assign(assigns, :csrf_token, Plug.CSRFProtection.get_csrf_token())

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={@csrf_token} />
        <title>Symphony Observability</title>
        <script defer src="/vendor/phoenix_html/phoenix_html.js"></script>
        <script defer src="/vendor/phoenix/phoenix.js"></script>
        <script defer src="/vendor/phoenix_live_view/phoenix_live_view.js"></script>
        <script>
          (function () {
            var storageKey = "symphony-dashboard-theme";
            var root = document.documentElement;
            var lightLabel = "Light mode";
            var darkLabel = "Dark mode";

            function resolveTheme() {
              try {
                var saved = window.localStorage.getItem(storageKey);
                if (saved === "light" || saved === "dark") return saved;
              } catch (_error) {}

              return window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches
                ? "dark"
                : "light";
            }

            function applyTheme(theme) {
              root.setAttribute("data-theme", theme);
              root.style.colorScheme = theme;
            }

            function syncThemeToggle(theme) {
              var toggle = document.querySelector("[data-theme-toggle]");
              if (!toggle) return;

              var isDark = theme === "dark";
              toggle.textContent = isDark ? lightLabel : darkLabel;
              toggle.setAttribute("aria-pressed", String(isDark));
            }

            var initialTheme = resolveTheme();
            applyTheme(initialTheme);

            window.__symphonyTheme = {
              toggle: function () {
                var nextTheme = root.getAttribute("data-theme") === "dark" ? "light" : "dark";
                applyTheme(nextTheme);

                try {
                  window.localStorage.setItem(storageKey, nextTheme);
                } catch (_error) {}

                window.dispatchEvent(new CustomEvent("symphony:theme-changed", {detail: nextTheme}));
              }
            };

            window.addEventListener("DOMContentLoaded", function () {
              syncThemeToggle(root.getAttribute("data-theme") || initialTheme);
            });

            window.addEventListener("symphony:theme-changed", function (event) {
              syncThemeToggle(event.detail);
            });

            document.addEventListener("click", function (event) {
              var toggle = event.target && event.target.closest("[data-theme-toggle]");
              if (!toggle) return;

              event.preventDefault();
              window.__symphonyTheme.toggle();
            });
          })();

          window.addEventListener("DOMContentLoaded", function () {
            var csrfToken = document
              .querySelector("meta[name='csrf-token']")
              ?.getAttribute("content");

            if (!window.Phoenix || !window.LiveView) return;

            var liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
              params: {_csrf_token: csrfToken}
            });

            liveSocket.connect();
            window.liveSocket = liveSocket;
          });
        </script>
        <link rel="stylesheet" href="/dashboard.css" />
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    ~H"""
    <main class="app-shell">
      <div class="app-toolbar">
        <button
          type="button"
          class="theme-toggle secondary"
          data-theme-toggle
          aria-pressed="false"
        >
          Dark mode
        </button>
      </div>
      {@inner_content}
    </main>
    """
  end
end
