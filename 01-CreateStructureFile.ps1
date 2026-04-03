$base = "E:\Partages"

$dossiers = @(
    "$base\BillU-Interne",
    "$base\BillU-Interne\Administratif",
    "$base\BillU-Interne\Technique",
    "$base\BillU-Interne\Projets-Internes",
    "$base\BillU-Interne\RH",
    "$base\EcoTech-Interne",
    "$base\EcoTech-Interne\Administratif",
    "$base\EcoTech-Interne\Technique",
    "$base\EcoTech-Interne\RH",
    "$base\Collaboration",
    "$base\Collaboration\Projets-Communs",
    "$base\Collaboration\Echanges",
    "$base\Collaboration\Echanges\BillU-vers-EcoTech",
    "$base\Collaboration\Echanges\EcoTech-vers-BillU",
    "$base\Collaboration\Documentation",
    "$base\Collaboration\Documentation\Procedures",
    "$base\Collaboration\Documentation\Contacts"
)

foreach ($dossier in $dossiers) {
    New-Item -ItemType Directory -Path $dossier -Force | Out-Null
    Write-Host "✅ Créé : $dossier"
}

Write-Host ""
Write-Host "=== Structure créée ==="
tree E:\Partages
