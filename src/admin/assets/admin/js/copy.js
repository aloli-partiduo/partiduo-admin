/* SPDX-License-Identifier: AGPL-3.0-or-later
   Bouton « Copier » d'un bloc de texte (journal d'une tâche) : copie le texte
   de l'élément visé par data-copy-target dans le presse-papiers. Délégation
   sur le document : marche aussi après un remplacement HTMX du corps de page. */
document.addEventListener("click", async (event) => {
  const button = event.target.closest("[data-copy-target]");
  if (!button) return;
  const target = document.getElementById(button.dataset.copyTarget);
  if (!target) return;
  const label = button.dataset.copyLabel || button.textContent;
  try {
    await navigator.clipboard.writeText(target.textContent);
    button.textContent = button.dataset.copiedLabel || "✓";
  } catch (error) {
    button.textContent = button.dataset.failedLabel || "✗";
  }
  setTimeout(() => { button.textContent = label; }, 2000);
});
