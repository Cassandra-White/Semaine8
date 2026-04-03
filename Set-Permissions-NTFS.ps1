# =============================================================================
# SET-PERMISSIONS-NTFS.ps1
# Script CORRIGÉ de configuration des permissions NTFS - Serveur de Fichiers BillU
#
# POURQUOI icacls et non Get-Acl/Set-Acl ?
#   - Get-Acl/Set-Acl retire TOUS les droits (y compris BUILTIN\Administrators)
#     avant de les réappliquer → risque de se couper la branche sur laquelle on est assis
#   - icacls opère de manière atomique et conserve toujours le compte qui lance
#     la commande, évitant ainsi tout blocage en cours d'exécution
#
# PRÉREQUIS :
#   - Exécuter en tant que BILLU\Administrateur sur FS-BILLU
#   - Les groupes AD doivent exister dans billu.local (tutoriel 03)
#   - Les groupes locaux doivent exister sur FS-BILLU (tutoriel 04)
#   - Les dossiers doivent exister (script de création du tutoriel 03)
#
# USAGE :
#   powershell -ExecutionPolicy Bypass -File Set-Permissions-NTFS.ps1
# =============================================================================

#Requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# =============================================================================
# VARIABLES — adapter si le nom du serveur ou du domaine diffère
# =============================================================================

$Base         = "D:\Partages"
$Domaine      = "BILLU"          # Nom NetBIOS du domaine
$NomServeur   = $env:COMPUTERNAME  # FS-BILLU automatiquement

# Groupes du domaine BillU
$BilluAdmins  = "$Domaine\GRP-FS-BillU-Admins"
$BilluUsers   = "$Domaine\GRP-FS-BillU-Users"

# Groupes locaux EcoTech (sur ce serveur)
$EcoAdmins    = "$NomServeur\GRP-Local-EcoTech-Admins"
$EcoUsers     = "$NomServeur\GRP-Local-EcoTech-Users"

# Comptes systèmes toujours présents
$System       = "NT AUTHORITY\SYSTEM"
$AdminBuiltin = "BUILTIN\Administrators"

# =============================================================================
# FONCTIONS UTILITAIRES
# =============================================================================

function Write-Titre { param([string]$Texte)
    Write-Host ""
    Write-Host "=== $Texte ===" -ForegroundColor Cyan
}

function Write-OK    { param([string]$Chemin)
    Write-Host "  ✅ OK : $Chemin" -ForegroundColor Green
}

function Write-Echec { param([string]$Chemin, [string]$Msg)
    Write-Host "  ❌ ECHEC : $Chemin — $Msg" -ForegroundColor Red
}

# -----------------------------------------------------------------------------
# Set-PermissionsIcacls
#   Applique des permissions NTFS sur un dossier via icacls.
#
#   Principe de fonctionnement (safe) :
#     1. /reset            → remet les permissions à l'état hérité par défaut
#                            Windows conserve toujours BUILTIN\Administrators lors du reset
#     2. /inheritance:d    → désactive l'héritage (sans copier les règles parentes)
#     3. /grant            → ajoute chaque nouvelle entrée
#
#   Flags icacls utilisés :
#     (OI)  = Object Inherit     → s'applique aux fichiers dans ce dossier
#     (CI)  = Container Inherit  → s'applique aux sous-dossiers
#     (IO)  = Inherit Only       → n'affecte que les enfants, pas le dossier lui-même
#     F     = Full Control
#     M     = Modify
#     RX    = Read & Execute
#     R     = Read
#     /Q    = mode silencieux (pas d'écho)
#     /C    = continue malgré les erreurs
# -----------------------------------------------------------------------------
function Set-PermissionsIcacls {
    param(
        [Parameter(Mandatory)][string]   $Chemin,
        [Parameter(Mandatory)][hashtable]$Droits
        # Droits = @{ "DOMAINE\Groupe" = "F|M|RX|R" }
    )

    Write-Host "  → Traitement : $Chemin"

    # --- Étape 1 : reset des permissions (remet Administrators en Full Control) ---
    $r = icacls $Chemin /reset /C /Q 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Echec $Chemin "Échec /reset : $r"; return }

    # --- Étape 2 : couper l'héritage du dossier parent (sans copier ses règles) ---
    $r = icacls $Chemin /inheritance:d /Q 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Echec $Chemin "Échec /inheritance:d : $r"; return }

    # --- Étape 3 : retirer les droits hérités résiduels sauf SYSTEM et Administrators ---
    #     On retire "Everyone" et "Authenticated Users" qui peuvent rester après le reset
    foreach ($compte in @("Everyone", "BUILTIN\Users", "NT AUTHORITY\Authenticated Users")) {
        icacls $Chemin /remove:g $compte /Q 2>&1 | Out-Null
    }

    # --- Étape 4 : s'assurer que SYSTEM et Administrators sont toujours là ---
    icacls $Chemin /grant "${System}:(OI)(CI)F"        /Q 2>&1 | Out-Null
    icacls $Chemin /grant "${AdminBuiltin}:(OI)(CI)F"  /Q 2>&1 | Out-Null

    # --- Étape 5 : appliquer les droits demandés ---
    foreach ($entree in $Droits.GetEnumerator()) {
        $compte = $entree.Key
        $droit  = $entree.Value

        # Convertir le niveau de droit en flag icacls
        $flag = switch ($droit) {
            "FullControl"      { "F"  }
            "Modify"           { "M"  }
            "ReadAndExecute"   { "RX" }
            "Read"             { "R"  }
            "ListDirectory"    { "(OI)(CI)(IO)RX" }   # voir le contenu, pas écrire
            default            { $droit }              # passer tel quel si déjà un flag icacls
        }

        # Pour les droits standard, on applique avec héritage (OI)(CI)
        if ($flag -notmatch "^\(") {
            $flag = "(OI)(CI)$flag"
        }

        $r = icacls $Chemin /grant "${compte}:${flag}" /Q 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "    ⚠️  Avertissement pour $compte : $r" -ForegroundColor Yellow
        }
    }

    Write-OK $Chemin
}

# =============================================================================
# VÉRIFICATIONS PRÉALABLES
# =============================================================================

Write-Titre "VÉRIFICATIONS PRÉALABLES"

# Le dossier de base existe-t-il ?
if (-not (Test-Path $Base)) {
    Write-Host "❌ Le dossier $Base n'existe pas. Lance d'abord le script de création des dossiers." -ForegroundColor Red
    exit 1
}
Write-Host "  ✅ Dossier $Base trouvé"

# Les groupes AD existent-ils ?
try {
    Import-Module ActiveDirectory -ErrorAction Stop
    foreach ($grp in @("GRP-FS-BillU-Admins","GRP-FS-BillU-Users","GRP-FS-EcoTech-Admins","GRP-FS-EcoTech-Users")) {
        $null = Get-ADGroup -Identity $grp -ErrorAction Stop
        Write-Host "  ✅ Groupe AD trouvé : $grp"
    }
} catch {
    Write-Host "  ⚠️  Module AD ou groupes AD inaccessibles depuis ce serveur (normal si pas de RSAT)" -ForegroundColor Yellow
    Write-Host "  → Les noms de groupes seront quand même utilisés dans les ACL" -ForegroundColor Yellow
}

# Les groupes locaux existent-ils ?
foreach ($grpLocal in @("GRP-Local-EcoTech-Admins","GRP-Local-EcoTech-Users")) {
    if (Get-LocalGroup -Name $grpLocal -ErrorAction SilentlyContinue) {
        Write-Host "  ✅ Groupe local trouvé : $grpLocal"
    } else {
        Write-Host "  ❌ Groupe local MANQUANT : $grpLocal — Lance d'abord le tutoriel 04 !" -ForegroundColor Red
        exit 1
    }
}

# =============================================================================
# APPLICATION DES PERMISSIONS
# =============================================================================

# -----------------------------------------------------------------------------
# 1. RACINE D:\Partages
#    Admins uniquement — les users n'ont pas accès à la racine directement
# -----------------------------------------------------------------------------
Write-Titre "RACINE D:\Partages"

Set-PermissionsIcacls -Chemin $Base -Droits @{
    $BilluAdmins = "FullControl"
    $EcoAdmins   = "FullControl"
}

# -----------------------------------------------------------------------------
# 2. BILLU-INTERNE
#    BillU Admins = Full Control
#    BillU Users  = Modify
#    EcoTech      = AUCUN ACCÈS (pas d'entrée)
# -----------------------------------------------------------------------------
Write-Titre "BILLU-INTERNE"

$DossiersBilluInterne = @(
    "$Base\BillU-Interne"
    "$Base\BillU-Interne\Administratif"
    "$Base\BillU-Interne\Technique"
    "$Base\BillU-Interne\Projets-Internes"
    "$Base\BillU-Interne\RH"
)

foreach ($d in $DossiersBilluInterne) {
    Set-PermissionsIcacls -Chemin $d -Droits @{
        $BilluAdmins = "FullControl"
        $BilluUsers  = "Modify"
        # EcoTech : absent = accès refusé
    }
}

# -----------------------------------------------------------------------------
# 3. ECOTECH-INTERNE
#    BillU Admins  = Full Control (ils gèrent le serveur)
#    BillU Users   = AUCUN ACCÈS
#    EcoTech Admins = Full Control
#    EcoTech Users  = Modify
# -----------------------------------------------------------------------------
Write-Titre "ECOTECH-INTERNE"

$DossiersEcoInterne = @(
    "$Base\EcoTech-Interne"
    "$Base\EcoTech-Interne\Administratif"
    "$Base\EcoTech-Interne\Technique"
    "$Base\EcoTech-Interne\RH"
)

foreach ($d in $DossiersEcoInterne) {
    Set-PermissionsIcacls -Chemin $d -Droits @{
        $BilluAdmins = "FullControl"
        $EcoAdmins   = "FullControl"
        $EcoUsers    = "Modify"
        # BillU Users : absent = accès refusé
    }
}

# -----------------------------------------------------------------------------
# 4. COLLABORATION (racine)
#    Admins des deux côtés = Full Control
#    Users des deux côtés = Lecture + liste des sous-dossiers uniquement
# -----------------------------------------------------------------------------
Write-Titre "COLLABORATION (racine)"

Set-PermissionsIcacls -Chemin "$Base\Collaboration" -Droits @{
    $BilluAdmins = "FullControl"
    $EcoAdmins   = "FullControl"
    $BilluUsers  = "ReadAndExecute"   # Peuvent naviguer dans le dossier
    $EcoUsers    = "ReadAndExecute"   # idem
}

# -----------------------------------------------------------------------------
# 5. COLLABORATION\PROJETS-COMMUNS
#    Tout le monde = Modify (travail collaboratif)
# -----------------------------------------------------------------------------
Write-Titre "COLLABORATION\PROJETS-COMMUNS"

Set-PermissionsIcacls -Chemin "$Base\Collaboration\Projets-Communs" -Droits @{
    $BilluAdmins = "FullControl"
    $EcoAdmins   = "FullControl"
    $BilluUsers  = "Modify"
    $EcoUsers    = "Modify"
}

# -----------------------------------------------------------------------------
# 6. COLLABORATION\ECHANGES
#    Racine : admins seulement (les users y accèdent via sous-dossiers)
# -----------------------------------------------------------------------------
Write-Titre "COLLABORATION\ECHANGES"

Set-PermissionsIcacls -Chemin "$Base\Collaboration\Echanges" -Droits @{
    $BilluAdmins = "FullControl"
    $EcoAdmins   = "FullControl"
    $BilluUsers  = "ReadAndExecute"
    $EcoUsers    = "ReadAndExecute"
}

# BillU dépose → EcoTech lit
Set-PermissionsIcacls -Chemin "$Base\Collaboration\Echanges\BillU-vers-EcoTech" -Droits @{
    $BilluAdmins = "FullControl"
    $EcoAdmins   = "FullControl"
    $BilluUsers  = "Modify"           # BillU écrit ici
    $EcoUsers    = "ReadAndExecute"   # EcoTech lit seulement
}

# EcoTech dépose → BillU lit
Set-PermissionsIcacls -Chemin "$Base\Collaboration\Echanges\EcoTech-vers-BillU" -Droits @{
    $BilluAdmins = "FullControl"
    $EcoAdmins   = "FullControl"
    $BilluUsers  = "ReadAndExecute"   # BillU lit seulement
    $EcoUsers    = "Modify"           # EcoTech écrit ici
}

# -----------------------------------------------------------------------------
# 7. COLLABORATION\DOCUMENTATION
#    BillU (admins + users) = Modify (créer/éditer la doc)
#    EcoTech = Lecture seule
# -----------------------------------------------------------------------------
Write-Titre "COLLABORATION\DOCUMENTATION"

$DossiersDoc = @(
    "$Base\Collaboration\Documentation"
    "$Base\Collaboration\Documentation\Procedures"
    "$Base\Collaboration\Documentation\Contacts"
)

foreach ($d in $DossiersDoc) {
    Set-PermissionsIcacls -Chemin $d -Droits @{
        $BilluAdmins = "FullControl"
        $EcoAdmins   = "FullControl"
        $BilluUsers  = "Modify"
        $EcoUsers    = "ReadAndExecute"   # Lecture seule pour EcoTech
    }
}

# =============================================================================
# RAPPORT FINAL
# =============================================================================

Write-Titre "RÉSUMÉ DES PERMISSIONS APPLIQUÉES"

$tous = @(
    $Base
    "$Base\BillU-Interne"
    "$Base\EcoTech-Interne"
    "$Base\Collaboration"
    "$Base\Collaboration\Projets-Communs"
    "$Base\Collaboration\Echanges\BillU-vers-EcoTech"
    "$Base\Collaboration\Echanges\EcoTech-vers-BillU"
    "$Base\Collaboration\Documentation"
)

foreach ($d in $tous) {
    Write-Host ""
    Write-Host "📁 $d" -ForegroundColor Yellow
    icacls $d /Q 2>&1 | Where-Object { $_ -match "GRP-|eco-|SYSTEM|Administrators" } |
        ForEach-Object { Write-Host "   $_" }
}

Write-Host ""
Write-Host "=== CONFIGURATION NTFS TERMINÉE ===" -ForegroundColor Green
Write-Host "Pour vérifier manuellement : clic droit sur un dossier → Propriétés → Sécurité"
