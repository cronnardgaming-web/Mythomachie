# Jeu de cartes mythologique (prototype)

Jeu de cartes jouable dans le navigateur, mélange de Hearthstone et de Hero Realms :
4 factions (Égyptiens, Hindous, Nordiques, Grecs), un marché commun et des créatures sur le plateau.

## Mettre le jeu en ligne avec GitHub Pages

1. Créez un dépôt **public** (par exemple `mythomachie`).
2. Déposez-y les fichiers `index.html`, `README.md`, `supabase.sql`, `supabase-phase4.sql` et `supabase-admin.sql` (« Add file », puis « Upload files »).
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

- Partie en ligne entre amis (« Jouer en ligne »), sans compte, grâce à Supabase.

## Jeu en ligne (Supabase)

Le jeu est relié au projet Supabase dont l’adresse et la clé publique sont écrites dans `index.html`.
Le fichier `supabase.sql` crée la table qui sauvegarde les parties : il suffit de l’exécuter une fois
dans Supabase (SQL Editor, puis Run). La connexion anonyme doit être activée
(Authentication, puis Sign In / Providers, puis « Allow anonymous sign-ins »).

## Collection, decks et boutique (phase 4)

Le fichier `supabase-phase4.sql` crée les tables et fonctions de la collection : profil, or, encre,
cartes possédées, decks, paquets, quête du jour. Exécutez-le une fois dans Supabase (SQL Editor, puis Run),
après `supabase.sql`.

Pour gérer l’économie depuis le jeu (prix des paquets, or gagné, chances, encre), ouvrez
« Administration », onglet « Serveur », et suivez les instructions pour vous déclarer administrateur.
Après avoir ajouté des cartes ou changé leur rareté, cliquez sur « Envoyer le catalogue ».

## Accès à l’administration

Exécutez `supabase-admin.sql` une fois dans Supabase. Ensuite, seul l’administrateur déclaré dans la table
`admins` voit le bouton « Administration ». Les autres joueurs utilisent toujours les cartes officielles
de `config.json`. Pour ajouter ou retirer un administrateur, modifiez la table `admins` dans Supabase
(Table Editor).

## Images en haute définition

Exécutez `supabase-images.sql` une fois dans Supabase, après `supabase-admin.sql`. Il crée le dossier public
« images », où seul l’administrateur peut envoyer des fichiers. Les images ajoutées depuis l’administration
du site (cartes et portraits des héros) y sont stockées en deux versions : haute définition pour la grande vue,
légère pour les parties. `config.json` ne contient alors que leurs adresses.

## Statistiques, pseudos et trophées

Exécutez `supabase-stats.sql` une fois dans Supabase, après `supabase-admin.sql`. Il ajoute le pseudo des joueurs,
la présence (qui est en ligne, sur quel écran), l’historique des parties et les statistiques. Les joueurs
retrouvent leurs chiffres et leurs trophées dans « Mon profil » ; l’administrateur dispose de l’onglet
« Statistiques » de l’administration (joueurs, héros, duels, cartes).

## Statistiques complètes (les deux camps)

`supabase-stats-duels.sql` (à exécuter après `supabase-stats.sql`) enregistre chaque partie avec ses deux camps :
joueur et ordinateur, hôte et invité en ligne, ou deux camps locaux pour une partie sur un même écran.
Il y a donc toujours autant de victoires que de défaites. Ce script remet l’historique des parties à zéro.

## Sécurité

Le dépôt est public : n’y mettez jamais de mot de passe ni la clé « service_role » de Supabase.
