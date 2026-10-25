/* SPDX-License-Identifier: AGPL-3.0-or-later
   Choix des modules et extensions d'un dossier (DECISIONS D-ADM-016) :
   confort seulement, le serveur refait chaque contrôle et la page marche
   sans ce script. Les règles viennent du catalogue de la console
   (`PartiduoAdmin::Catalog`), rendues en attributs de chaque case :

   * data-requires : pièces requises, toutes ; data-requires-any : groupes
     (séparés par des espaces) dont une pièce au moins est requise ;
   * data-conflicts : pièces incompatibles, dans les deux sens ;
   * data-excluded-kinds, data-required-kinds : types de dossier qui
     excluent ou requièrent la pièce ;
   * data-regimes : régimes fiscaux pour lesquels elle vaut (vide : tous) ;
   * data-choice : choix exclusif (boutons radio, D-ADM-019) auquel elle
     appartient, avec un bouton « ni l'un ni l'autre » (data-pd-none).

   Cocher une pièce coche ce qu'elle requiert (« requis par … ») ; décocher
   une pièce requise décoche, après confirmation, ce qui en dépend ; une
   pièce incompatible avec une pièce cochée est désactivée, avec la raison ;
   un foyer ne voit pas les pièces qu'il n'admet pas, ni un dossier celles
   que son régime n'admet pas (un dossier belge : ni micro-entreprise, ni
   profession libérale, groupe « Régime d'imposition » masqué ; ni URSSAF,
   TELEDEC, Chorus Pro, EsaLink). Changer de bouton radio décoche, après
   confirmation, ce qui dépendait de l'ancien choix. Sur la page des
   modules, un rappel liste ce qui sera activé et désactivé (données
   conservées). */
(function () {
  "use strict";

  function words(value) {
    return (value || "").split(/\s+/).filter(Boolean);
  }

  function fill(template, params) {
    return (template || "").replace(/%\{(\w+)\}/g, function (match, name) {
      return Object.prototype.hasOwnProperty.call(params, name) ? params[name] : match;
    });
  }

  function setup(root) {
    var form = root.closest("form");
    var messages = JSON.parse(root.dataset.messages || "{}");
    var kinds = JSON.parse(root.dataset.kinds || "{}");
    var regimes = JSON.parse(root.dataset.regimes || "{}");
    var lang = document.documentElement.lang || "fr";
    var live = root.querySelector("[data-pd-live]");
    var changes = form.querySelector("[data-pd-changes]");
    var initial = words(root.dataset.initial);
    var boxes = {};
    var rules = {};

    root.querySelectorAll("input[data-label]").forEach(function (box) {
      boxes[box.value] = box;
      rules[box.value] = {
        requires: words(box.dataset.requires),
        any: words(box.dataset.requiresAny).map(function (group) { return group.split(","); }),
        conflicts: words(box.dataset.conflicts),
        excluded: words(box.dataset.excludedKinds),
        required: words(box.dataset.requiredKinds),
        regimes: words(box.dataset.regimes),
        choice: box.dataset.choice || ""
      };
    });
    var codes = Object.keys(boxes);

    // Pièce cochée de chaque choix exclusif : changer de bouton radio
    // décoche l'ancienne sans événement, il faut s'en souvenir.
    var selected = {};
    function remember() {
      root.querySelectorAll("[data-pd-choice]").forEach(function (group) {
        var on = codes.filter(function (code) { return rules[code].choice === group.dataset.pdChoice && boxes[code].checked; });
        selected[group.dataset.pdChoice] = on[0] || "";
      });
    }

    function kind() {
      if (root.dataset.kind) return root.dataset.kind;
      var radio = form.querySelector("input[name=kind]:checked");
      return radio ? radio.value : "company";
    }

    function regime() {
      if (root.dataset.regime) return root.dataset.regime;
      var radio = form.querySelector("input[name=regime]:checked");
      return radio ? radio.value : "";
    }

    function regimeExcluded(code, current) {
      var list = rules[code].regimes;
      return !!current && list.length > 0 && list.indexOf(current) < 0;
    }

    // Deux pièces d'un même choix exclusif : le bouton radio les sépare.
    function peers(code, other) {
      return !!rules[code].choice && !!rules[other] && rules[other].choice === rules[code].choice;
    }

    function checked(code) {
      return !!boxes[code] && boxes[code].checked;
    }

    function wrapper(code) {
      return boxes[code].closest("[data-pd-piece]");
    }

    function names(list, type) {
      var quoted = list.map(function (code) {
        return fill(messages.quoted, { name: boxes[code] ? boxes[code].dataset.label : code });
      });
      try {
        return new Intl.ListFormat(lang, { type: type || "conjunction" }).format(quoted);
      } catch (error) {
        return quoted.join(", ");
      }
    }

    function announce(text) {
      if (live && text) live.textContent = text;
    }

    // Pièces que le type de dossier ou son régime exclut, ou dont une
    // dépendance est exclue ou absente de la page (même point fixe que le
    // serveur).
    function unavailable(current, fiscal) {
      var out = {};
      codes.forEach(function (code) {
        if (rules[code].excluded.indexOf(current) >= 0 || regimeExcluded(code, fiscal)) out[code] = true;
      });
      var gone = function (code) { return !rules[code] || out[code]; };
      var grew = true;
      while (grew) {
        grew = false;
        codes.forEach(function (code) {
          if (out[code]) return;
          var rule = rules[code];
          if (rule.requires.some(gone) || rule.any.some(function (group) { return group.every(gone); })) {
            out[code] = true;
            grew = true;
          }
        });
      }
      return out;
    }

    // Pièces cochées qui ont besoin de `code` : il est l'une de leurs
    // dépendances, ou le seul coché d'un de leurs groupes.
    function requirers(code) {
      return codes.filter(function (other) {
        if (!checked(other)) return false;
        var rule = rules[other];
        return rule.requires.indexOf(code) >= 0 || rule.any.some(function (group) {
          return group.indexOf(code) >= 0 && group.filter(checked).length === 1;
        });
      });
    }

    // Une pièce d'un choix exclusif n'est pas cochée d'office si une autre
    // pièce du même choix l'est déjà.
    function usable(code) {
      if (!boxes[code] || boxes[code].disabled || wrapper(code).hidden) return false;
      var choice = rules[code].choice;
      return !choice || !selected[choice] || selected[choice] === code;
    }

    // Coche ce que `code` requiert, de proche en proche.
    function ensure(code, added) {
      var rule = rules[code];
      rule.requires.forEach(function (dependency) {
        if (checked(dependency) || !usable(dependency)) return;
        boxes[dependency].checked = true;
        added.push(dependency);
        ensure(dependency, added);
      });
      rule.any.forEach(function (group) {
        if (group.some(checked)) return;
        var pick = group.filter(usable)[0];
        if (!pick) return;
        boxes[pick].checked = true;
        added.push(pick);
        ensure(pick, added);
      });
    }

    // Pièces cochées qui perdraient une dépendance si `code` était décoché.
    function dependents(code) {
      var off = {};
      off[code] = true;
      var on = function (other) { return checked(other) && !off[other]; };
      var grew = true;
      while (grew) {
        grew = false;
        codes.forEach(function (other) {
          if (off[other] || !checked(other) || boxes[other].hasAttribute("data-pd-locked")) return;
          var rule = rules[other];
          var lost = rule.requires.some(function (dependency) { return off[dependency]; }) ||
            rule.any.some(function (group) {
              return group.some(function (dependency) { return off[dependency]; }) && !group.some(on);
            });
          if (lost) {
            off[other] = true;
            grew = true;
          }
        });
      }
      delete off[code];
      return Object.keys(off);
    }

    function refresh() {
      var current = kind();
      var fiscal = regime();
      var gone = unavailable(current, fiscal);
      var dropped = [];
      codes.forEach(function (code) {
        var box = boxes[code];
        var rule = rules[code];
        var wrap = wrapper(code);
        var reasons = [];
        // À la création, le type se choisit sur la page : un foyer ne voit
        // pas ce qu'il n'admet pas. Sur la page des modules, le serveur a
        // déjà écarté ces pièces, sauf celles encore actives.
        var hide = gone[code] && !root.dataset.kind;
        if (hide && box.checked) {
          box.checked = false;
          dropped.push(code);
        }
        wrap.hidden = !!hide;
        if (rule.required.indexOf(current) >= 0) {
          box.checked = true;
          box.disabled = true;
          reasons.push(fill(messages.kind_required, { kind: kinds[current] || current }));
        } else if (!box.hasAttribute("data-pd-locked")) {
          var against = rule.conflicts.filter(function (other) { return checked(other) && !peers(code, other); });
          box.disabled = !box.checked && (against.length > 0 || !!gone[code]);
          if (against.length) reasons.push(fill(messages.incompatible, { others: names(against) }));
          else if (gone[code] && !box.checked) {
            if (rule.excluded.indexOf(current) < 0 && regimeExcluded(code, fiscal)) {
              reasons.push(fill(messages.regime, { regime: regimes[fiscal] || fiscal }));
            } else {
              reasons.push(fill(messages.unavailable, { kind: kinds[current] || current }));
            }
          }
        }
        var needed = box.checked ? requirers(code) : [];
        if (needed.length) reasons.push(fill(messages.required_by, { others: names(needed) }));
        // Dépendance absente (page renvoyée par le serveur avec une erreur).
        var missing = box.checked ? rule.requires.filter(function (other) { return !checked(other); }) : [];
        var groups = box.checked ? rule.any.filter(function (group) { return !group.some(checked); }) : [];
        if (missing.length) reasons.push(fill(messages.missing, { others: names(missing) }));
        groups.forEach(function (group) { reasons.push(fill(messages.missing, { others: names(group, "disjunction") })); });
        wrap.querySelector("[data-pd-status]").textContent = reasons.join(" · ");
        wrap.classList.toggle("is-unavailable", box.disabled && !box.checked);
        wrap.classList.toggle("is-missing", missing.length + groups.length > 0);
        wrap.classList.toggle("is-needed", needed.length > 0 && missing.length + groups.length === 0);
      });
      // Choix exclusif : « ni l'un ni l'autre » quand plus rien n'est
      // coché ; groupe masqué quand aucune de ses pièces n'est proposée.
      root.querySelectorAll("[data-pd-choice]").forEach(function (group) {
        var none = group.querySelector("[data-pd-none] input");
        if (none && !group.querySelector("input[data-label]:checked")) none.checked = true;
        group.hidden = !group.querySelector("[data-pd-piece]:not([hidden])");
      });
      root.querySelectorAll("[data-pd-family]").forEach(function (family) {
        family.hidden = !family.querySelector("[data-pd-piece]:not([hidden])");
      });
      remember();
      summary();
      return dropped;
    }

    // Pièce décochée (case, ou bouton radio quitté) : ce qui en dépend est
    // décoché après confirmation. Rend faux si la personne renonce.
    function release(code) {
      var lost = dependents(code);
      if (!lost.length) return true;
      if (!window.confirm(fill(messages.confirm, { piece: names([code]), others: names(lost) }))) return false;
      lost.forEach(function (other) { boxes[other].checked = false; });
      announce(fill(messages.unchecked, { others: names(lost) }));
      return true;
    }

    // Rappel de la page des modules : ce qui sera activé, désactivé.
    function summary() {
      if (!changes) return;
      var enable = codes.filter(function (code) { return checked(code) && initial.indexOf(code) < 0; });
      var disable = initial.filter(function (code) { return boxes[code] && !checked(code); });
      var parts = [];
      if (enable.length) parts.push(fill(messages.enable, { others: names(enable) }));
      if (disable.length) parts.push(fill(messages.disable, { others: names(disable) }));
      changes.textContent = parts.join(" ");
    }

    form.addEventListener("change", function (event) {
      var target = event.target;
      if (target.name === "kind" || target.name === "regime") {
        var dropped = refresh();
        if (dropped.length) announce(fill(messages.unchecked, { others: names(dropped) }));
        return;
      }
      // Bouton radio d'un choix exclusif : l'ancien choix est quitté.
      var choice = target.type === "radio" ? (target.dataset.choice || target.dataset.pdNone || "") : "";
      if (choice) {
        var previous = selected[choice];
        if (previous && previous !== target.value && !release(previous)) {
          boxes[previous].checked = true;
          refresh();
          return;
        }
        if (!target.matches("input[data-label]")) {
          refresh();
          return;
        }
      }
      if (!target.matches("input[data-label]")) return;
      var code = target.value;
      if (target.checked) {
        refresh();
        var added = [];
        ensure(code, added);
        refresh();
        if (added.length) announce(fill(messages.checked, { piece: names([code]), others: names(added) }));
        return;
      }
      if (!release(code)) target.checked = true;
      refresh();
    });

    // Une case désactivée n'est pas envoyée : celles que le script a
    // cochées et verrouillées (pièce requise par le type) le redeviennent.
    form.addEventListener("submit", function () {
      codes.forEach(function (code) {
        var box = boxes[code];
        if (box.checked && box.disabled && !box.hasAttribute("data-pd-locked")) box.disabled = false;
      });
    });

    // Rappels de type et d'incompatibilité masqués : l'état de chaque case
    // les dit quand ils jouent.
    root.classList.add("is-live");
    remember();
    refresh();
  }

  function start() {
    document.querySelectorAll("[data-pd-pieces]").forEach(setup);
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start);
  else start();
})();
