// 日本語を既定とし、英語圏のブラウザと明示的な選択だけ英語にする。
(function () {
  var root = document.documentElement;
  var KEY = "tethr-lang";

  function apply(lang) {
    root.classList.toggle("lang-en", lang === "en");
    root.lang = lang;
    var b = document.getElementById("lang");
    if (b) {
      b.textContent = lang === "en" ? "日本語" : "English";
      b.setAttribute("aria-label", lang === "en" ? "日本語に切り替える" : "Switch to English");
    }
  }

  var saved = null;
  try { saved = localStorage.getItem(KEY); } catch (e) {}
  var lang = saved || ((navigator.language || "").toLowerCase().indexOf("ja") === 0 ? "ja" : "en");
  apply(lang);

  document.addEventListener("click", function (e) {
    if (!e.target.closest || !e.target.closest("#lang")) return;
    lang = lang === "en" ? "ja" : "en";
    apply(lang);
    try { localStorage.setItem(KEY, lang); } catch (e) {}
  });
})();
