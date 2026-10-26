// SPDX-License-Identifier: AGPL-3.0-or-later
// Assistants (DECISIONS D-ADM-018) : confort seulement, tout fonctionne sans
// ce script. Après chaque étape servie par HTMX, le focus se place sur le
// titre de l'étape (« Étape 2 sur 4 : … »), que les lecteurs d'écran
// annoncent ; une étape refusée (422) remplace aussi le contenu, pour
// montrer ses erreurs.
(function () {
  "use strict";
  // Script rechargé avec chaque étape servie par HTMX : une seule fois.
  if (window.partiduoWizard) {
    return;
  }
  window.partiduoWizard = true;

  function focusStep() {
    var title = document.querySelector("[data-pd-step-focus]");
    if (title && document.activeElement !== title) {
      title.focus({ preventScroll: false });
    }
  }

  document.addEventListener("DOMContentLoaded", focusStep);
  // Rafraîchissement de l'attente de l'exécutant (D-ADM-022) : le focus
  // reste où il est.
  document.addEventListener("htmx:afterSettle", function (event) {
    var target = event.detail && event.detail.target;
    if (target && target.id === "pd-wizard-live") {
      return;
    }
    focusStep();
  });
  document.addEventListener("htmx:beforeSwap", function (event) {
    var source = event.detail.elt;
    if (event.detail.xhr && event.detail.xhr.status === 422 && source && source.closest && source.closest("[data-pd-wizard]")) {
      event.detail.shouldSwap = true;
      event.detail.isError = false;
    }
  });
})();
