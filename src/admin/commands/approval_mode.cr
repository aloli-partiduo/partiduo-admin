# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoAdmin
  module Commands
    # `manage approval-mode-single --firm=<id> --reason=<motif>`
    #
    # Recours hors de l'interface (D-ADM-023) : repasse une structure à la
    # validation à une personne quand plus personne ne peut valider la
    # demande d'un autre — typiquement le parc sans cabinet à deux
    # super-admins dont l'un a disparu (aucun cabinet n'a ce besoin : le
    # super-admin y valide en dernier recours). Réservé à qui a la main sur
    # le serveur ; motif exigé ; trace `dual_approval.cli_off` au journal
    # d'audit, avec les demandes en attente, qui le restent.
    class ApprovalModeSingle < Marten::CLI::Manage::Command::Base
      command_name :"approval-mode-single"
      help "Repasse une structure à la validation à une personne (recours, D-ADM-023)."

      @firm = ""
      @reason = ""

      def setup
        on_option_with_arg("firm", "id", "numéro de la structure (/firms/<id>/approval-mode)") { |value| @firm = value }
        on_option_with_arg("reason", "motif", "motif consigné au journal d'audit") { |value| @reason = value }
      end

      def run
        firm = @firm.to_i64?.try { |id| Firm.filter(id: id).first }
        return print_error_and_exit("structure inconnue : #{@firm}") if firm.nil?
        return print_error_and_exit("motif exigé (--reason, cinq caractères au moins).") if @reason.strip.size < 5
        now = Config.now
        changed = Firm.filter(id: firm.pk, dual_approval: true).update(dual_approval: false, dual_approval_changed_at: now)
        if changed != 1
          print("#{firm.name} : déjà à une personne.")
          return
        end
        Audit.log(nil, "dual_approval.cli_off", target: firm, actor_label: "cli",
          detail: {"before" => ApprovalMode::DUAL, "after" => ApprovalMode::SINGLE, "reason" => @reason.strip,
                   "team" => ApprovalMode.team_size(firm).to_s, "pending" => ApprovalMode.pending_count(firm, now).to_s})
        print("#{firm.name} : validation à une personne.")
      end
    end
  end
end
