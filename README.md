# Jeu de cartes mythologique (prototype)

Jeu de cartes jouable dans le navigateur, mélange de Hearthstone et de Hero Realms :
4 factions (Égyptiens, Hindous, Nordiques, Grecs), un marché commun et des créatures sur le plateau.

## Mettre le jeu en ligne avec GitHub Pages

1. Créez un dépôt **public** (par exemple `mythomachie`).
2. Déposez-y les fichiers `index.html` et `README.md` (« Add file », puis « Upload files »).
3. Dans « Settings », puis « Pages », choisissez « Deploy from a branch », la branche `main` et le dossier `/ (root)`.
4. Après une ou deux minutes, le jeu est en ligne à `https://VOTRE-PSEUDO.github.io/NOM-DU-DEPOT/`.

## Partager vos cartes et vos réglages avec les joueurs

Sans fichier `config.json`, le site utilise les 120 cartes d’origine.

1. Ouvrez le jeu (sur Claude ou sur votre site), puis « Administration », onglet « Sauvegarde ».
2. Cliquez sur « Télécharger config.json ». Le fichier contient vos cartes, vos règles, vos factions et vos images.
3. Déposez `config.json` dans le dépôt, à côté de `index.html`. S’il existe déjà, remplacez-le.
4. Les joueurs reçoivent la nouvelle version à leur prochaine visite.

Refaites ces étapes après chaque série de modifications.

## Ce qui fonctionne sur le site

- Partie contre l’ordinateur.
- Partie à deux sur le même écran.
- Administration (dans votre navigateur ; publiez avec `config.json`).

Le jeu en ligne entre amis arrivera à l’étape suivante, avec Supabase.

## Sécurité

Le dépôt est public : n’y mettez jamais de mot de passe ni la clé « service_role » de Supabase.
