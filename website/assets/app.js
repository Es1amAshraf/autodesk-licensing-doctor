(function () {
  "use strict";

  var html = document.documentElement;
  var langToggle = document.getElementById("langToggle");
  var shotImage = document.getElementById("shotImage");
  var shotTitle = document.getElementById("shotTitle");
  var heroShot = document.querySelector(".hero-art .window img");
  var heroWindowTitle = document.getElementById("heroWindowTitle");
  var shotTabs = Array.prototype.slice.call(document.querySelectorAll(".shot-tab"));
  var year = document.getElementById("year");
  var pageDefault = html.getAttribute("data-default-lang") === "ar" ? "ar" : "en";
  var assetPrefix = html.getAttribute("data-asset-prefix") || "";
  var currentLang = pageDefault;

  function setShot(lang) {
    if (!shotImage) { return; }
    var isArabic = lang === "ar";
    shotImage.src = assetPrefix + (isArabic ? "assets/screenshot-ar-20261021.png" : "assets/screenshot-en-20261021.png");
    shotImage.alt = isArabic ? "ÙˆØ§Ø¬Ù‡Ø© UNLOCK DIGITAL Ø¨Ø§Ù„Ø¹Ø±Ø¨ÙŠØ©" : "UNLOCK DIGITAL English interface";
    if (shotTitle) {
      shotTitle.textContent = isArabic
        ? "UNLOCK DIGITAL â€” Ø¯ÙƒØªÙˆØ± ØªØ±Ø®ÙŠØµ Ø£ÙˆØªÙˆØ¯ÙŠØ³Ùƒ"
        : "UNLOCK DIGITAL â€” Autodesk Licensing Doctor";
    }
    shotTabs.forEach(function (tab) {
      var active = tab.getAttribute("data-shot") === lang;
      tab.classList.toggle("active", active);
      tab.setAttribute("aria-selected", active ? "true" : "false");
    });
  }

  function setHero(lang) {
    var isArabic = lang === "ar";
    if (heroShot) {
      heroShot.src = assetPrefix + (isArabic ? "assets/screenshot-ar-20261021.png" : "assets/screenshot-en-20261021.png");
    }
    if (heroWindowTitle) {
      heroWindowTitle.textContent = isArabic
        ? "UNLOCK DIGITAL â€” Ø¯ÙƒØªÙˆØ± ØªØ±Ø®ÙŠØµ Ø£ÙˆØªÙˆØ¯ÙŠØ³Ùƒ"
        : "UNLOCK DIGITAL â€” Autodesk Licensing Doctor";
    }
  }

  function applyLanguage(lang) {
    currentLang = lang === "ar" ? "ar" : "en";
    html.lang = currentLang;
    html.dir = currentLang === "ar" ? "rtl" : "ltr";

    var translatable = document.querySelectorAll("[data-en]");
    Array.prototype.forEach.call(translatable, function (el) {
      if (!el.hasAttribute("data-ar")) {
        el.setAttribute("data-ar", el.textContent);
      }
      el.textContent = currentLang === "ar"
        ? el.getAttribute("data-ar")
        : el.getAttribute("data-en");
    });

    if (langToggle) {
      langToggle.textContent = currentLang === "ar" ? "English" : "Ø§Ù„Ø¹Ø±Ø¨ÙŠØ©";
      langToggle.setAttribute("hreflang", currentLang === "ar" ? "en" : "ar");
      if (window.location.protocol !== "file:") {
        langToggle.setAttribute("href", currentLang === "ar" ? "/" : "/ar/");
      }
    }

    setShot(currentLang);
    setHero(currentLang);
    document.title = currentLang === "ar"
      ? "UNLOCK DIGITAL â€” Ø¯ÙƒØªÙˆØ± ØªØ±Ø®ÙŠØµ Ø£ÙˆØªÙˆØ¯ÙŠØ³Ùƒ"
      : "UNLOCK DIGITAL â€” Autodesk Licensing Doctor";
  }

  if (langToggle) {
    langToggle.addEventListener("click", function (event) {
      var next = currentLang === "ar" ? "en" : "ar";
      if (window.location.protocol === "file:") {
        event.preventDefault();
        applyLanguage(next);
        return;
      }
      event.preventDefault();
      window.location.href = next === "ar" ? "/ar/" : "/";
    });
  }

  // Screenshot tabs only switch the screenshot, not the site language.
  shotTabs.forEach(function (tab) {
    tab.addEventListener("click", function () {
      setShot(tab.getAttribute("data-shot") === "ar" ? "ar" : "en");
    });
  });

  // Click a hash to copy it.
  Array.prototype.forEach.call(document.querySelectorAll(".hash code"), function (code) {
    code.style.cursor = "copy";
    code.title = "Click to copy";
    code.addEventListener("click", function () {
      var text = code.textContent.trim();
      var done = function () {
        var old = code.textContent;
        code.textContent = currentLang === "ar" ? "ØªÙ… Ø§Ù„Ù†Ø³Ø® âœ“" : "Copied âœ“";
        window.setTimeout(function () { code.textContent = old; }, 1200);
      };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(done, done);
      } else {
        var area = document.createElement("textarea");
        area.value = text;
        area.style.position = "fixed";
        area.style.opacity = "0";
        document.body.appendChild(area);
        area.select();
        try { document.execCommand("copy"); } catch (e) { /* ignore */ }
        document.body.removeChild(area);
        done();
      }
    });
  });

  if (year) { year.textContent = String(new Date().getFullYear()); }

  var queryLang = null;
  try { queryLang = new URLSearchParams(window.location.search).get("lang"); } catch (e) { /* ignore */ }

  // Keep old ?lang= links working, but send crawlers and users to the static pages.
  if (window.location.protocol !== "file:") {
    if (queryLang === "ar" && pageDefault !== "ar") {
      window.location.replace("/ar/");
      return;
    }
    if (queryLang === "en" && pageDefault === "ar") {
      window.location.replace("/");
      return;
    }
  }

  applyLanguage(pageDefault);
})();
