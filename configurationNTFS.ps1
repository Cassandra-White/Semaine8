$base        = "E:\Partages"
$domaine     = "BILLU"

# Groupes AD BillU
$billuAdmins = "$domaine\GRP-FS-BillU-Admins"
$billuUsers  = "$domaine\GRP-FS-BillU-Users"

# Groupes locaux EcoTech (sur FS-BILLU)
$ecoAdmins   = "FS-BILLU\GRP-Local-EcoTech-Admins"
$ecoUsers    = "FS-BILLU\GRP-Local-EcoTech-Users"

# Compte SYSTEM (toujours Full Control)
$system      = "NT AUTHORITY\SYSTEM"
$adminLocal  = "BUILTIN\Administrators"

# --- FONCTION UTILITAIRE ---
function Set-FolderPermissions {
    param(
        [string]$Chemin,
        [array]$Permissions,
        [bool]$CasserHeritage = $false
    )

    Write-Host "Configuration permissions : $Chemin"

    $acl = Get-Acl -Path $Chemin

    # Casser l'héritage si demandé
    if ($CasserHeritage) {
        $acl.SetAccessRuleProtection($true, $false)
        # $true = bloquer l'héritage du parent
        # $false = NE PAS copier les permissions héritées
    }

    # Supprimer toutes les règles existantes
    $acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) }

    # Ajouter les nouvelles règles
    foreach ($perm in $Permissions) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $perm.Compte,
            $perm.Droit,
            "ContainerInherit,ObjectInherit",  # S'applique aux sous-dossiers ET fichiers
            "None",
            "Allow"
        )
        $acl.AddAccessRule($rule)
    }

    Set-Acl -Path $Chemin -AclObject $acl
    Write-Host "  ✅ OK"
}

# 1. DOSSIER RACINE E:\Partages
# Permissions de base : seuls les admins ont accès (les users ont "List" via les sous-dossiers)
Write-Host ""
Write-Host "=== DOSSIER RACINE ===" -ForegroundColor Cyan

Set-FolderPermissions -Chemin $base -CasserHeritage $true -Permissions @(
    @{ Compte = $system;      Droit = "FullControl" },
    @{ Compte = $adminLocal;  Droit = "FullControl" },
    @{ Compte = $billuAdmins; Droit = "FullControl" },
    @{ Compte = $ecoAdmins;   Droit = "FullControl" }
)

# 2. BILLU-INTERNE (et sous-dossiers)
# BillU Admins = Full Control, BillU Users = Modify
# EcoTechSolutions = PAS D'ACCÈS
Write-Host ""
Write-Host "=== BILLU-INTERNE ===" -ForegroundColor Cyan

$dossiersBilluInterne = @(
    "$base\BillU-Interne",
    "$base\BillU-Interne\Administratif",
    "$base\BillU-Interne\Technique",
    "$base\BillU-Interne\Projets-Internes",
    "$base\BillU-Interne\RH"
)

foreach ($d in $dossiersBilluInterne) {
    Set-FolderPermissions -Chemin $d -CasserHeritage $true -Permissions @(
        @{ Compte = $system;      Droit = "FullControl" },
        @{ Compte = $adminLocal;  Droit = "FullControl" },
        @{ Compte = $billuAdmins; Droit = "FullControl" },
        @{ Compte = $billuUsers;  Droit = "Modify" }
        # EcoTech : PAS d'entrée = aucun accès
    )
}

# 3. ECOTECH-INTERNE (et sous-dossiers)
# BillU Admins = Full Control (ils gèrent le serveur)
# BillU Users = PAS D'ACCÈS
# EcoTech Admins = Full Control
# EcoTech Users = Modify
Write-Host ""
Write-Host "=== ECOTECH-INTERNE ===" -ForegroundColor Cyan

$dossiersEcoInterne = @(
    "$base\EcoTech-Interne",
    "$base\EcoTech-Interne\Administratif",
    "$base\EcoTech-Interne\Technique",
    "$base\EcoTech-Interne\RH"
)

foreach ($d in $dossiersEcoInterne) {
    Set-FolderPermissions -Chemin $d -CasserHeritage $true -Permissions @(
        @{ Compte = $system;      Droit = "FullControl" },
        @{ Compte = $adminLocal;  Droit = "FullControl" },
        @{ Compte = $billuAdmins; Droit = "FullControl" },
        @{ Compte = $ecoAdmins;   Droit = "FullControl" },
        @{ Compte = $ecoUsers;    Droit = "Modify" }
        # BillU Users : PAS d'entrée = aucun accès
    )
}

# 4. COLLABORATION (dossier racine)
# Tout le monde voit le dossier mais ne peut rien créer directement dedans
# (Lecture + List seulement)
Write-Host ""
Write-Host "=== COLLABORATION ===" -ForegroundColor Cyan

# Dossier racine Collaboration : accès list uniquement pour les users
$aclCollab = Get-Acl -Path "$base\Collaboration"
$aclCollab.SetAccessRuleProtection($true, $false)
$aclCollab.Access | ForEach-Object { $aclCollab.RemoveAccessRule($_) }

# Note : "ReadAndExecute" + "Synchronize" pour pouvoir naviguer dans le dossier
$droitsListSeulement = [System.Security.AccessControl.FileSystemRights]"ReadAndExecute, Synchronize"
$heritage = [System.Security.AccessControl.InheritanceFlags]"ContainerInherit,ObjectInherit"
$propagation = [System.Security.AccessControl.PropagationFlags]"None"
$typeDroit = [System.Security.AccessControl.AccessControlType]"Allow"

$aclCollab.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($system, "FullControl", $heritage, $propagation, $typeDroit)))
$aclCollab.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($adminLocal, "FullControl", $heritage, $propagation, $typeDroit)))
$aclCollab.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($billuAdmins, "FullControl", $heritage, $propagation, $typeDroit)))
$aclCollab.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($ecoAdmins, "FullControl", $heritage, $propagation, $typeDroit)))
$aclCollab.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($billuUsers, $droitsListSeulement, $heritage, $propagation, $typeDroit)))
$aclCollab.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($ecoUsers, $droitsListSeulement, $heritage, $propagation, $typeDroit)))

Set-Acl -Path "$base\Collaboration" -AclObject $aclCollab
Write-Host "  ✅ Collaboration (racine) : OK"

# 5. COLLABORATION\PROJETS-COMMUNS
# Tout le monde = Modify (travail collaboratif)
Set-FolderPermissions -Chemin "$base\Collaboration\Projets-Communs" -CasserHeritage $true -Permissions @(
    @{ Compte = $system;      Droit = "FullControl" },
    @{ Compte = $adminLocal;  Droit = "FullControl" },
    @{ Compte = $billuAdmins; Droit = "FullControl" },
    @{ Compte = $ecoAdmins;   Droit = "FullControl" },
    @{ Compte = $billuUsers;  Droit = "Modify" },
    @{ Compte = $ecoUsers;    Droit = "Modify" }
)

# 6. COLLABORATION\ECHANGES
# Racine : List seulement
# BillU-vers-EcoTech : BillU dépose (Modify), EcoTech lit (Read)
# EcoTech-vers-BillU : EcoTech dépose (Modify), BillU lit (Read)
Set-FolderPermissions -Chemin "$base\Collaboration\Echanges" -CasserHeritage $true -Permissions @(
    @{ Compte = $system;      Droit = "FullControl" },
    @{ Compte = $adminLocal;  Droit = "FullControl" },
    @{ Compte = $billuAdmins; Droit = "FullControl" },
    @{ Compte = $ecoAdmins;   Droit = "FullControl" }
)

# BillU dépose → EcoTech lit
Set-FolderPermissions -Chemin "$base\Collaboration\Echanges\BillU-vers-EcoTech" -CasserHeritage $true -Permissions @(
    @{ Compte = $system;      Droit = "FullControl" },
    @{ Compte = $adminLocal;  Droit = "FullControl" },
    @{ Compte = $billuAdmins; Droit = "FullControl" },
    @{ Compte = $ecoAdmins;   Droit = "FullControl" },
    @{ Compte = $billuUsers;  Droit = "Modify" },         # BillU écrit
    @{ Compte = $ecoUsers;    Droit = "ReadAndExecute" }  # EcoTech lit
)

# EcoTech dépose → BillU lit
Set-FolderPermissions -Chemin "$base\Collaboration\Echanges\EcoTech-vers-BillU" -CasserHeritage $true -Permissions @(
    @{ Compte = $system;      Droit = "FullControl" },
    @{ Compte = $adminLocal;  Droit = "FullControl" },
    @{ Compte = $billuAdmins; Droit = "FullControl" },
    @{ Compte = $ecoAdmins;   Droit = "FullControl" },
    @{ Compte = $billuUsers;  Droit = "ReadAndExecute" },  # BillU lit
    @{ Compte = $ecoUsers;    Droit = "Modify" }           # EcoTech écrit
)

# 7. COLLABORATION\DOCUMENTATION
# BillU (admins+users) : Modify pour créer/éditer la doc
# EcoTech : Lecture seule
$dossierDoc = @(
    "$base\Collaboration\Documentation",
    "$base\Collaboration\Documentation\Procedures",
    "$base\Collaboration\Documentation\Contacts"
)

foreach ($d in $dossierDoc) {
    Set-FolderPermissions -Chemin $d -CasserHeritage $true -Permissions @(
        @{ Compte = $system;      Droit = "FullControl" },
        @{ Compte = $adminLocal;  Droit = "FullControl" },
        @{ Compte = $billuAdmins; Droit = "FullControl" },
        @{ Compte = $ecoAdmins;   Droit = "FullControl" },
        @{ Compte = $billuUsers;  Droit = "Modify" },
        @{ Compte = $ecoUsers;    Droit = "ReadAndExecute" }
    )
}

Write-Host ""
Write-Host "=== CONFIGURATION TERMINÉE ===" -ForegroundColor Green
Write-Host "Toutes les permissions NTFS ont été configurées."
