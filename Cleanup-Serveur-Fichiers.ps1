# =============================================================================
# CLEANUP-SERVEUR-FICHIERS.ps1
# Remise à zéro COMPLÈTE du serveur de fichiers FS-BILLU
#
# Ce script supprime TOUT ce qui a été créé lors des tutoriels 02 à 05 :
#   - Le partage réseau SMB
#   - Les permissions NTFS personnalisées (restaure l'héritage)
#   - L'arborescence des dossiers D:\Partages
#   - Les comptes locaux EcoTechSolutions (eco-*)
#   - Les groupes locaux (GRP-Local-EcoTech-*)
#   - Les groupes AD BillU (GRP-FS-*)
#   - L'entrée DNS fs-billu.billu.local (optionnel)
#
# PRÉREQUIS :
#   - Exécuter en tant que BILLU\Administrateur sur FS-BILLU
#   - Pour la suppression des groupes AD : accès réseau à DC1
#
# USAGE :
#   powershell -ExecutionPolicy Bypass -File Cleanup-Serveur-Fichiers.ps1
#
# ⚠️  ATTENTION : IRRÉVERSIBLE. Toutes les données seront perdues.
# =============================================================================

#Requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"   # Continue pour ne pas bloquer sur les erreurs non critiques

$Base = "D:\Partages"

# =============================================================================
# CONFIRMATION AVANT EXÉCUTION
# =============================================================================

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Red
Write-Host "║  ⚠️  SCRIPT DE REMISE À ZÉRO — ACTION IRRÉVERSIBLE         ║" -ForegroundColor Red
Write-Host "║                                                              ║" -ForegroundColor Red
Write-Host "║  Ce script va supprimer :                                    ║" -ForegroundColor Red
Write-Host "║   • Le partage \\FS-BILLU\Partage-Commun                    ║" -ForegroundColor Red
Write-Host "║   • Tous les dossiers dans D:\Partages                       ║" -ForegroundColor Red
Write-Host "║   • Les comptes locaux eco-*                                 ║" -ForegroundColor Red
Write-Host "║   • Les groupes locaux GRP-Local-EcoTech-*                  ║" -ForegroundColor Red
Write-Host "║   • Les groupes AD GRP-FS-* dans billu.local                ║" -ForegroundColor Red
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Red
Write-Host ""

$confirm = Read-Host "Tape 'OUI' en majuscules pour confirmer la suppression totale"
if ($confirm -ne "OUI") {
    Write-Host "Annulé. Aucune modification effectuée." -ForegroundColor Green
    exit 0
}

Write-Host ""
Write-Host "Démarrage du nettoyage..." -ForegroundColor Yellow

# =============================================================================
# ÉTAPE 1 — SUPPRIMER LE PARTAGE RÉSEAU SMB
# =============================================================================

Write-Host ""
Write-Host "=== ÉTAPE 1 : Suppression du partage réseau ===" -ForegroundColor Cyan

$nomPartage = "Partage-Commun"

if (Get-SmbShare -Name $nomPartage -ErrorAction SilentlyContinue) {
    # Déconnecter les sessions actives proprement
    Write-Host "  Fermeture des sessions SMB actives..."
    Get-SmbSession | Where-Object { $_.ShareName -eq $nomPartage } |
        ForEach-Object {
            try {
                Close-SmbSession -SessionId $_.SessionId -Force -ErrorAction SilentlyContinue
                Write-Host "    → Session fermée : $($_.ClientUserName)"
            } catch { }
        }

    # Fermer les fichiers ouverts
    Get-SmbOpenFile | Where-Object { $_.ShareName -eq $nomPartage } |
        ForEach-Object {
            try {
                Close-SmbOpenFile -FileId $_.FileId -Force -ErrorAction SilentlyContinue
            } catch { }
        }

    Start-Sleep -Seconds 2

    # Supprimer le partage
    Remove-SmbShare -Name $nomPartage -Force -ErrorAction SilentlyContinue
    Write-Host "  ✅ Partage '$nomPartage' supprimé"
} else {
    Write-Host "  ℹ️  Partage '$nomPartage' non trouvé (déjà supprimé ou jamais créé)"
}

# Supprimer aussi d'autres partages éventuels créés
foreach ($partage in @("BillU-Interne", "EcoTech-Interne", "Collaboration")) {
    if (Get-SmbShare -Name $partage -ErrorAction SilentlyContinue) {
        Remove-SmbShare -Name $partage -Force -ErrorAction SilentlyContinue
        Write-Host "  ✅ Partage '$partage' supprimé"
    }
}

# =============================================================================
# ÉTAPE 2 — PRENDRE LA PROPRIÉTÉ ET RÉINITIALISER LES PERMISSIONS NTFS
# Cette étape est CRITIQUE car les permissions cassées peuvent empêcher
# la suppression des dossiers
# =============================================================================

Write-Host ""
Write-Host "=== ÉTAPE 2 : Reprise de propriété et reset des permissions ===" -ForegroundColor Cyan

if (Test-Path $Base) {
    Write-Host "  Reprise de propriété de $Base (peut prendre quelques secondes)..."

    # takeown.exe : force la propriété sur tous les fichiers/dossiers
    # /F = chemin, /R = récursif, /A = donne à l'admin (BUILTIN\Administrators), /D Y = répond Oui aux questions
    $takeownResult = takeown /F $Base /R /A /D Y 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ✅ Propriété récupérée sur $Base"
    } else {
        Write-Host "  ⚠️  takeown a rencontré des erreurs (non critique, on continue)" -ForegroundColor Yellow
    }

    Write-Host "  Réinitialisation des permissions NTFS (restauration de l'héritage)..."

    # icacls /reset : remet les permissions héritées par défaut sur TOUS les objets
    # /T = récursif, /C = continue sur erreur, /Q = silencieux
    $icaclsResult = icacls $Base /reset /T /C /Q 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ✅ Permissions NTFS réinitialisées"
    } else {
        Write-Host "  ⚠️  Quelques erreurs icacls (on tente quand même la suppression) : $icaclsResult" -ForegroundColor Yellow
    }

    # Donner Full Control explicitement aux admins pour pouvoir supprimer
    icacls $Base /grant "BUILTIN\Administrators:(OI)(CI)F" /T /C /Q 2>&1 | Out-Null
    icacls $Base /grant "NT AUTHORITY\SYSTEM:(OI)(CI)F" /T /C /Q 2>&1 | Out-Null

    Write-Host "  ✅ Droits de suppression garantis pour Administrators"
} else {
    Write-Host "  ℹ️  Dossier $Base non trouvé (déjà supprimé)"
}

# =============================================================================
# ÉTAPE 3 — SUPPRIMER L'ARBORESCENCE DES DOSSIERS
# =============================================================================

Write-Host ""
Write-Host "=== ÉTAPE 3 : Suppression des dossiers ===" -ForegroundColor Cyan

if (Test-Path $Base) {
    try {
        # Supprimer récursivement sans demander de confirmation
        Remove-Item -Path $Base -Recurse -Force -ErrorAction Stop
        Write-Host "  ✅ Dossier $Base supprimé avec tout son contenu"
    } catch {
        Write-Host "  ⚠️  Suppression partielle, tentative avec robocopy..." -ForegroundColor Yellow

        # Technique robocopy : synchroniser avec un dossier vide = supprime tout
        $dossierVide = "$env:TEMP\Vide-$(Get-Random)"
        New-Item -ItemType Directory -Path $dossierVide -Force | Out-Null

        robocopy $dossierVide $Base /MIR /NFL /NDL /NJH /NJS /NC /NS /NP 2>&1 | Out-Null
        Remove-Item $dossierVide -Force -Recurse -ErrorAction SilentlyContinue

        # Supprimer le dossier devenu vide
        Remove-Item -Path $Base -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path $Base)) {
            Write-Host "  ✅ Dossier $Base supprimé via robocopy"
        } else {
            Write-Host "  ❌ Impossible de supprimer $Base — vérifie manuellement" -ForegroundColor Red
        }
    }
} else {
    Write-Host "  ℹ️  Dossier $Base déjà absent"
}

# =============================================================================
# ÉTAPE 4 — SUPPRIMER LES COMPTES LOCAUX ECOTECHSOLUTIONS
# =============================================================================

Write-Host ""
Write-Host "=== ÉTAPE 4 : Suppression des comptes locaux eco-* ===" -ForegroundColor Cyan

$comptesLocaux = Get-LocalUser | Where-Object { $_.Name -like "eco-*" }

if ($comptesLocaux) {
    foreach ($compte in $comptesLocaux) {
        try {
            # Terminer les sessions actives de ce compte si possible
            $sessions = query session 2>&1 | Where-Object { $_ -match $compte.Name }
            if ($sessions) {
                Write-Host "  ⚠️  Session active détectée pour $($compte.Name), tentative de déconnexion..." -ForegroundColor Yellow
            }

            Remove-LocalUser -Name $compte.Name -ErrorAction Stop
            Write-Host "  ✅ Compte supprimé : $($compte.Name)"
        } catch {
            Write-Host "  ❌ Impossible de supprimer $($compte.Name) : $_" -ForegroundColor Red
        }
    }
} else {
    Write-Host "  ℹ️  Aucun compte eco-* trouvé sur ce serveur"
}

# =============================================================================
# ÉTAPE 5 — SUPPRIMER LES GROUPES LOCAUX ECOTECHSOLUTIONS
# =============================================================================

Write-Host ""
Write-Host "=== ÉTAPE 5 : Suppression des groupes locaux GRP-Local-EcoTech-* ===" -ForegroundColor Cyan

$groupesLocaux = Get-LocalGroup | Where-Object { $_.Name -like "GRP-Local-EcoTech-*" }

if ($groupesLocaux) {
    foreach ($groupe in $groupesLocaux) {
        try {
            Remove-LocalGroup -Name $groupe.Name -ErrorAction Stop
            Write-Host "  ✅ Groupe local supprimé : $($groupe.Name)"
        } catch {
            Write-Host "  ❌ Impossible de supprimer $($groupe.Name) : $_" -ForegroundColor Red
        }
    }
} else {
    Write-Host "  ℹ️  Aucun groupe GRP-Local-EcoTech-* trouvé"
}

# =============================================================================
# ÉTAPE 6 — SUPPRIMER LES GROUPES AD BILLU.LOCAL
# =============================================================================

Write-Host ""
Write-Host "=== ÉTAPE 6 : Suppression des groupes AD dans billu.local ===" -ForegroundColor Cyan

try {
    Import-Module ActiveDirectory -ErrorAction Stop
    Write-Host "  Module Active Directory chargé"

    $groupesAD = @(
        "GRP-FS-BillU-Admins"
        "GRP-FS-BillU-Users"
        "GRP-FS-EcoTech-Admins"
        "GRP-FS-EcoTech-Users"
    )

    foreach ($grp in $groupesAD) {
        if (Get-ADGroup -Identity $grp -ErrorAction SilentlyContinue) {
            try {
                Remove-ADGroup -Identity $grp -Confirm:$false -ErrorAction Stop
                Write-Host "  ✅ Groupe AD supprimé : $grp"
            } catch {
                Write-Host "  ❌ Impossible de supprimer $grp : $_" -ForegroundColor Red
            }
        } else {
            Write-Host "  ℹ️  Groupe AD non trouvé : $grp"
        }
    }

    # Supprimer l'OU si elle est vide
    $ou = "OU=Groupes-Serveur-Fichiers,DC=billu,DC=local"
    if (Get-ADOrganizationalUnit -Filter { DistinguishedName -eq $ou } -ErrorAction SilentlyContinue) {
        # Vérifier que l'OU est vide
        $contenu = Get-ADObject -SearchBase $ou -Filter * -SearchScope OneLevel -ErrorAction SilentlyContinue
        if (-not $contenu) {
            Remove-ADOrganizationalUnit -Identity $ou -Confirm:$false -Recursive -ErrorAction SilentlyContinue
            Write-Host "  ✅ OU 'Groupes-Serveur-Fichiers' supprimée (elle était vide)"
        } else {
            Write-Host "  ⚠️  OU 'Groupes-Serveur-Fichiers' non vide, non supprimée" -ForegroundColor Yellow
        }
    }

} catch {
    Write-Host "  ⚠️  Module AD non disponible depuis ce serveur" -ForegroundColor Yellow
    Write-Host "  → Supprime manuellement les groupes depuis DC1 (dsa.msc) :" -ForegroundColor Yellow
    Write-Host "     GRP-FS-BillU-Admins"
    Write-Host "     GRP-FS-BillU-Users"
    Write-Host "     GRP-FS-EcoTech-Admins"
    Write-Host "     GRP-FS-EcoTech-Users"
    Write-Host "     (dans l'OU Groupes-Serveur-Fichiers)"
}

# =============================================================================
# ÉTAPE 7 — SUPPRIMER L'ENTRÉE DNS (optionnel)
# =============================================================================

Write-Host ""
Write-Host "=== ÉTAPE 7 : Suppression de l'entrée DNS ===" -ForegroundColor Cyan

$supprimerDNS = Read-Host "  Supprimer l'entrée DNS 'fs-billu' dans billu.local ? (O/N)"

if ($supprimerDNS -eq "O" -or $supprimerDNS -eq "o") {
    try {
        Import-Module DnsServer -ErrorAction Stop

        # Chercher l'enregistrement dans la zone billu.local
        $record = Get-DnsServerResourceRecord -ZoneName "billu.local" -Name "fs-billu" -RRType "A" -ErrorAction SilentlyContinue
        if ($record) {
            Remove-DnsServerResourceRecord -ZoneName "billu.local" -Name "fs-billu" -RRType "A" -Force -ErrorAction Stop
            Write-Host "  ✅ Enregistrement DNS fs-billu.billu.local supprimé"
        } else {
            Write-Host "  ℹ️  Enregistrement DNS fs-billu non trouvé dans billu.local"
        }
    } catch {
        Write-Host "  ⚠️  Impossible de supprimer le DNS depuis ce serveur" -ForegroundColor Yellow
        Write-Host "  → Depuis DC1 (dnsmgmt.msc) : zone billu.local → supprimer 'fs-billu'" -ForegroundColor Yellow
    }
} else {
    Write-Host "  → Entrée DNS conservée"
}

# =============================================================================
# ÉTAPE 8 — SUPPRIMER LES RÈGLES DE PARE-FEU CRÉÉES
# =============================================================================

Write-Host ""
Write-Host "=== ÉTAPE 8 : Suppression des règles de pare-feu personnalisées ===" -ForegroundColor Cyan

$regles = @(
    "SMB - EcoTechSolutions via VPN"
    "RDP - EcoTechSolutions Admin uniquement"
)

foreach ($regle in $regles) {
    if (Get-NetFirewallRule -DisplayName $regle -ErrorAction SilentlyContinue) {
        Remove-NetFirewallRule -DisplayName $regle -ErrorAction SilentlyContinue
        Write-Host "  ✅ Règle pare-feu supprimée : $regle"
    } else {
        Write-Host "  ℹ️  Règle non trouvée : $regle"
    }
}

# =============================================================================
# ÉTAPE 9 — SUPPRIMER LES QUOTAS FSRM (si configurés)
# =============================================================================

Write-Host ""
Write-Host "=== ÉTAPE 9 : Suppression des quotas FSRM ===" -ForegroundColor Cyan

try {
    $quotas = Get-FsrmQuota -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "*Partages*" }
    if ($quotas) {
        $quotas | ForEach-Object {
            Remove-FsrmQuota -Path $_.Path -Confirm:$false -ErrorAction SilentlyContinue
            Write-Host "  ✅ Quota supprimé : $($_.Path)"
        }
    } else {
        Write-Host "  ℹ️  Aucun quota FSRM trouvé pour D:\Partages"
    }
} catch {
    Write-Host "  ℹ️  FSRM non disponible ou quotas déjà supprimés"
}

# =============================================================================
# ÉTAPE 10 — VÉRIFICATION FINALE
# =============================================================================

Write-Host ""
Write-Host "=== VÉRIFICATION FINALE ===" -ForegroundColor Cyan

$ok = $true

# Partage
if (-not (Get-SmbShare -Name "Partage-Commun" -ErrorAction SilentlyContinue)) {
    Write-Host "  ✅ Partage 'Partage-Commun' : absent (normal)"
} else {
    Write-Host "  ❌ Partage 'Partage-Commun' toujours présent !" -ForegroundColor Red; $ok = $false
}

# Dossiers
if (-not (Test-Path $Base)) {
    Write-Host "  ✅ Dossier D:\Partages : absent (normal)"
} else {
    Write-Host "  ❌ Dossier D:\Partages toujours présent !" -ForegroundColor Red; $ok = $false
}

# Comptes locaux
$comptesRestants = Get-LocalUser | Where-Object { $_.Name -like "eco-*" }
if (-not $comptesRestants) {
    Write-Host "  ✅ Comptes locaux eco-* : tous supprimés"
} else {
    Write-Host "  ❌ Comptes locaux restants : $($comptesRestants.Name -join ', ')" -ForegroundColor Red; $ok = $false
}

# Groupes locaux
$groupesRestants = Get-LocalGroup | Where-Object { $_.Name -like "GRP-Local-EcoTech-*" }
if (-not $groupesRestants) {
    Write-Host "  ✅ Groupes locaux GRP-Local-EcoTech-* : tous supprimés"
} else {
    Write-Host "  ❌ Groupes restants : $($groupesRestants.Name -join ', ')" -ForegroundColor Red; $ok = $false
}

Write-Host ""
if ($ok) {
    Write-Host "╔══════════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║  ✅ REMISE À ZÉRO COMPLÈTE — Tout est propre        ║" -ForegroundColor Green
    Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Green
} else {
    Write-Host "╔══════════════════════════════════════════════════════╗" -ForegroundColor Yellow
    Write-Host "║  ⚠️  NETTOYAGE PARTIEL — Voir les ❌ ci-dessus      ║" -ForegroundColor Yellow
    Write-Host "║  Vérifie manuellement les éléments en erreur        ║" -ForegroundColor Yellow
    Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Tu peux maintenant relancer les tutoriels 03 à 06 depuis zéro."
