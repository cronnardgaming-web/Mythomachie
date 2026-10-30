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

## Paquets par faction

`supabase-boosters.sql` (à exécuter après `supabase-phase4.sql`) ajoute la faction au catalogue du serveur et permet
d’acheter, en plus du paquet classique, un paquet par faction (même prix, mêmes chances). Après avoir ajouté des cartes
ou changé leur faction, renvoyez le catalogue depuis l’administration (onglet Serveur).

## Modifier l’or et l’encre d’un joueur

`supabase-admin-joueurs.sql` permet à l’administrateur de corriger l’or et l’encre d’un joueur depuis l’onglet
« Statistiques » de l’administration (bouton « Modifier » dans la liste des joueurs).

## Saisons

`supabase-saisons.sql` (à exécuter après `supabase-alertes-detaillees.sql`) : saisons de 12 travaux (deux ouverts par
semaine), quêtes de saison calculées par le serveur depuis l’ouverture de leur travail, 4 paliers de récompenses
(or, encre, carte, paquet, illustration, titre), cartes de saison absentes des paquets et non fabricables jusqu’à la
fin de la saison. Chaque partie enregistre aussi les combos, équipements, cartes bannies, palier de Dévotion et PV
de fin de partie. Les saisons se créent dans l’administration (onglet Saisons), puis « Envoyer la saison au serveur ».

## Alertes détaillées

`supabase-alertes-detaillees.sql` (à exécuter après tous les autres scripts) : chaque alerte liée à une partie
note le numéro de ticket et la cause exacte du blocage (champ hors limites, carte absente du catalogue, durée…).
Les parties acceptées ou refusées restent les mêmes ; seules les informations des alertes sont plus précises.

## Correctif des statistiques

`supabase-correctif-stats.sql` (à exécuter après `supabase-recompenses.sql`) : une carte absente du catalogue du
serveur (ajoutée dans l’administration sans « Envoyer le catalogue ») ne fait plus refuser la partie ni déclencher
d’alerte ; elle est simplement ignorée dans les statistiques. L’administration signale les cartes manquantes.

## Quêtes du jour et trophées

`supabase-recompenses.sql` (à exécuter après `supabase-variantes.sql`) met en place :
- 3 quêtes du jour par joueur (15 or chacune, une quête remplaçable par jour), calculées par le serveur ;
- des trophées à 4 rangs (bronze, argent, or, platine), dont 4 trophées de panthéon, avec des récompenses
  en or ou en paquets offerts, réclamables une seule fois ;
- une réserve de paquets offerts, qui s’ouvrent gratuitement dans la boutique.

## Illustrations alternatives, cartes promotionnelles et boosters spéciaux

`supabase-variantes.sql` (à exécuter après `supabase-surveillance.sql`) ajoute :
- les **illustrations alternatives** : créées dans la fiche d’une carte (onglet Cartes), elles ne changent que
  l’apparence ; les joueurs les débloquent une fois pour toutes (un doublon est converti en encre) et choisissent
  celle qu’ils affichent dans leur collection ;
- les **cartes promotionnelles** (case dans la fiche d’une carte) : absentes du booster principal et des boosters de
  panthéon, elles ne se fabriquent pas et ne se recyclent pas ;
- les **boosters spéciaux** (écran Boosters) : leur contenu est choisi carte par carte et illustration par
  illustration.

Après chaque changement : onglet Serveur, « Envoyer le catalogue », puis exporter config.json.

## Surveillance des comportements suspects

`supabase-surveillance.sql` (à exécuter après `supabase-securite.sql`) enregistre chaque tentative refusée par le
serveur (récompense sans partie, statistiques impossibles, quête non terminée, deck illégal…) et calcule les
comportements inhabituels (taux de victoire anormal, parties très nombreuses ou très courtes, arrangements possibles
entre deux joueurs). Tout est consultable dans l’onglet « Surveillance » de l’administration.

## Sécurité, niveau 1 (anti-triche)

`supabase-securite.sql` (à exécuter en dernier) fait du serveur le seul juge de l’économie :
chaque partie reçoit un ticket du serveur ; la récompense et les statistiques ne sont acceptées qu’une fois
par ticket, après une durée minimale (2 minutes par défaut, réglage `duree_min_partie` de la table `economie`),
et avec des valeurs plausibles. La quête du jour est calculée par le serveur. Les decks sont vérifiés (cartes
possédées, limites d’exemplaires, 30 cartes au plus). En ligne, l’hôte vérifie le deck de l’invité auprès du
serveur, et l’invité refuse une partie dont les cartes diffèrent des cartes officielles.

## Sécurité

Le dépôt est public : n’y mettez jamais de mot de passe ni la clé « service_role » de Supabase.
