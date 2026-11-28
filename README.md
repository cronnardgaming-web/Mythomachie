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

## 2 contre 2

`supabase-2v2.sql` (après les autres scripts) : les parties en 2 contre 2 sont enregistrées (ticket, durée minimale,
statistiques vérifiées) et rapportent de l’or comme une partie classique. Trois quêtes du jour propres au mode,
et des statistiques dédiées (page du mode et profil). Ces parties comptent aussi dans les statistiques générales
et les trophées, mais pas dans les quêtes du jour classiques, la saison ou le classement.

## 2 contre 2 en ligne (étape 1 : salons)

`supabase-2v2-ligne.sql` (après `supabase-2v2-suite.sql` et `supabase-correctif-2v2.sql`) : salons privés (code),
recherche de partie (regroupement jusqu’à 4 joueurs), choix des places, lancement par l’hôte (les places libres
deviennent des bots après 15 secondes), un ticket par joueur humain, Elo propre au 2 contre 2 (cotes figées au
lancement, aucune cote contre des bots seuls) et classement du 2 contre 2. Étape 2 (partie en temps réel, dans
index.html) : l’hôte fait tourner la partie et les bots, chaque joueur voit la partie depuis sa place et envoie ses
actions en ordres numérotés (refusés hors de son tour), un joueur silencieux 20 secondes est remplacé par l’ordinateur,
et chaque joueur humain enregistre sa partie avec son propre ticket (or, quêtes, statistiques, bonus, cote).

## Minuteur de tour et abandons

`supabase-abandons.sql` (après `supabase-2v2-ligne-suite.sql`) : présence des joueurs pendant la partie, abandons
(bouton, déconnexion de plus de 60 secondes, 2 tours expirés de suite), réclamation de la victoire quand l’adversaire
est parti, perte de cote d’au moins 15 points pour un abandon, forfait en 2 contre 2 quand toute une équipe humaine est
partie, perte divisée par deux pour un joueur dont l’allié est parti, clôture des parties abandonnées par tous.
Le minuteur (90 secondes par tour) ne s’applique qu’aux parties en ligne comptant au moins 2 joueurs humains ;
ses réglages sont dans l’administration, onglet Règles.

## Joueurs en ligne

`supabase-joueurs-en-ligne.sql` : nombre de joueurs actifs ces 2 dernières minutes, affiché sur l’accueil.

## 2 contre 2 en ligne (étape 3)

`supabase-2v2-ligne-suite.sql` (après `supabase-2v2-ligne.sql`) : invitation d’un ami dans un salon (bannière chez
l’ami invité, entre amis seulement) et reprise du rôle d’hôte quand l’hôte quitte la partie (le joueur humain suivant
reprend la partie, l’ordinateur joue la place de l’ancien hôte). Le classement du 2 contre 2 est un onglet de la page
Classement. Rappel : la cote du 2 contre 2 ne change que face à au moins un joueur humain adverse.

## Correctif du 2 contre 2

`supabase-correctif-2v2.sql` (à exécuter avec `supabase-2v2.sql`) : la table des tickets de partie n’acceptait que
les modes « ia », « duo » et « enligne » ; sans ce correctif, les parties de 2 contre 2 ne sont pas comptées.

## 2 contre 2 (suite)

`supabase-2v2-suite.sql` (après `supabase-2v2.sql`) : victoire bonus du jour (la première victoire en 2 contre 2
de la journée rapporte un bonus, 30 or par défaut, réglable avec la clé « bonus_victoire_2v2 ») et deux trophées
propres au mode : « Frères d’armes » (victoires) et « Indestructibles » (victoires sans chute).

## Règles de blocage des parties

`supabase-reglages-blocage.sql` : durée minimale d’une partie 75 secondes, 60 parties par heure au maximum.

## Recyclage des exemplaires en trop

`supabase-recyclage-surplus.sql` (après `supabase-variantes.sql`) : le bouton « Tout recycler » de la collection
transforme en encre, en une seule fois, tous les exemplaires au-delà du maximum utile d’un deck (mêmes règles que le
recyclage carte par carte). Sans ce script, le bouton fonctionne quand même, exemplaire par exemplaire.

## Correctif des cadeaux automatiques

`supabase-correctif-cadeaux-auto.sql` (après `supabase-cadeaux-auto.sql`) : les parties de 2 contre 2 comptent
désormais pour les paliers. Après l’exécution, cliquez sur « Envoyer maintenant aux joueurs ayant déjà atteint ces
paliers » pour servir ceux qui les avaient atteints grâce au 2 contre 2.

## Cadeaux automatiques

`supabase-cadeaux-auto.sql` (après `supabase-social.sql`) : onglet « Cadeaux automatiques » de l’administration.
Dès qu’un joueur atteint un nombre de parties (contre l’ordinateur ou en ligne), il reçoit automatiquement un
message avec cadeau dans sa boîte aux lettres, une seule fois par palier. {pseudo} et {parties} sont remplacés
dans le titre et le texte. Un bouton sert les joueurs qui avaient déjà atteint un palier avant sa création.

## Saison à venir

`supabase-saison-a-venir.sql` (après `supabase-saisons.sql`) : une saison active dont la date de début n’est pas
encore arrivée apparaît sur l’accueil (« Ouverture le … ») et sa page se visite en aperçu (travaux fermés, récompenses).
Les illustrations des travaux s’ajoutent dans l’onglet Saisons et restent dans config.json.

## Correctif des fonctions de statistiques

`supabase-correctif-fonctions-stats.sql` (après `supabase-simulations.sql`) : si les statistiques affichent
« Could not choose the best candidate function », ce script supprime les anciennes versions des fonctions.

## Parties simulées

`supabase-simulations.sql` (à exécuter après les autres scripts) : les fichiers de simulations s’importent depuis la
vue d’ensemble des statistiques (« Importer un fichier de simulations »). Elles sont comptées à part, incluses par
défaut dans les statistiques des héros et des cartes (case « Inclure les parties simulées »), et ne comptent jamais
pour les joueurs (quêtes, trophées, saison, classement). Un bouton permet de toutes les effacer.

## Amis, boîte aux lettres et nouveautés

`supabase-social.sql` (à exécuter après les autres scripts) : amis (recherche de pseudo, adversaires récents,
demandes, présence en ligne), défis entre amis (la partie compte pour le classement), boîte aux lettres (messages
de l’équipe avec cadeaux : or, encre, carte, paquet, illustration ; envoi à un joueur, une sélection ou tous),
notes de mise à jour (onglet « Notes de mise à jour » de l’administration, bouton « Nouveautés » de l’accueil).

## Correctif des quêtes remplacées

`supabase-correctif-quetes.sql` (à exécuter après `supabase-recompenses.sql`) : une quête du jour obtenue en
remplacement ne compte que les parties jouées après le remplacement (les 3 quêtes du jour comptent dès minuit).

## Classement Elo

`supabase-classement.sql` (à exécuter après les autres scripts) : chaque partie en ligne (avec un code ou par la
« Partie classée ») met à jour la cote Elo des deux joueurs (1 200 au départ, K = 40 sur les 20 premières parties,
puis 20). L’invité confirme le résultat ; en cas de désaccord, les points sont annulés et l’onglet Surveillance
le signale. La « Partie classée » associe automatiquement deux joueurs de niveau proche.

## Fiche joueur (administration)

`supabase-fiche-joueur.sql` (à exécuter après les autres scripts) : depuis la liste des joueurs, le bouton « Fiche »
ouvre le profil complet d’un joueur (statistiques, dernières parties, collection, illustrations) et permet de modifier
son or et son encre, de lui ajouter ou retirer des cartes, et de lui offrir ou retirer une illustration alternative.

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

## Langues (français / anglais)
Le joueur choisit sa langue dans les Réglages (« Langue / Language ») ; par défaut, le jeu suit la langue du navigateur.
L’interface est traduite dans le code. Le contenu (noms des cartes, divinités, pouvoirs, saisons, boosters, illustrations) se traduit dans **Admin › Le jeu › Traductions** : chaque texte français a un champ anglais, avec une proposition à accepter ou corriger. Les traductions partent dans config.json : exportez-le pour les publier. Un texte sans traduction reste affiché en français.
Messages de la boîte aux lettres, notes de mise à jour et cadeaux automatiques : chacun a une « Version anglaise (facultative) » dans l’admin. Exécutez une fois **supabase-langues.sql** (après supabase-social.sql et supabase-cadeaux-auto.sql) pour l’activer.
En ligne, le journal de partie circule en français et chaque joueur le lit dans sa langue : un joueur anglophone peut affronter un joueur francophone.

## Soutenir le jeu (PayPal)
Dans **Admin › Publication › Soutenir le jeu**, collez le lien de votre bouton de don PayPal (https://www.paypal.biz/…, https://paypal.me/… ou https://www.paypal.com/donate/?hosted_button_id=…), puis exportez config.json. Un bouton « Soutenir le jeu » apparaît sur l’accueil et dans les crédits ; il ouvre PayPal dans un nouvel onglet. Seuls les liens PayPal en https sont acceptés. Lien vide : le bouton est masqué.

## Bêta test
Pendant la bêta, l’accueil affiche un bandeau « Bêta test » et un tampon « Bêta » sur le logo. **Admin › Publication › Bêta test** : modifier le texte (et sa version anglaise) ou décocher la mention à la sortie de la bêta, puis exporter config.json.

## Cartes de saison (correctif)
Exécutez **supabase-correctif-cartes-saison.sql** : il rétablit l’interdiction de fabriquer ou de tirer en paquet une carte de saison avant la fin de la saison (protection effacée si supabase-variantes.sql ou supabase-boosters.sql a été relancé après supabase-saisons.sql). Puis, dans l’admin : Cartes › « Envoyer le catalogue ». À relancer si vous ré-exécutez un jour l’un de ces deux anciens scripts.

## Saison : travaux enchaînés
Exécutez **supabase-saison-travaux-enchaines.sql** (après supabase-saisons.sql) : un travail ne se débloque qu’une fois le précédent accompli (et sa date d’ouverture passée), et ses quêtes ne comptent que les parties jouées depuis ce déblocage. Les parties de 2 contre 2 comptent désormais pour les quêtes de saison.

## Cadeaux automatiques sous condition, registre des achats
- Exécutez **supabase-cadeaux-conditions.sql** : dans Admin › Récompenses › Cadeaux automatiques, un palier peut dépendre d’un nombre de parties jouées entre deux dates (ex. 100 parties pendant la bêta) ou d’un nombre de travaux accomplis dans une saison (ex. les 12 travaux d’Héraclès). Le message et son cadeau (une carte promotionnelle par exemple) partent dès que la condition est remplie.
- Exécutez **supabase-achats.sql** : Admin › Publication › Achats et soutiens, registre des sommes reçues (brut, frais PayPal, net), totaux par mois, export CSV pour la comptabilité. Le lien de soutien PayPal ajoute le pseudo et le début de l’identifiant du joueur à l’objet de la transaction.

## Jouer entre joueurs
Exécuter `supabase-jouer-entre-joueurs.sql` une fois (SQL Editor, puis Run), après `supabase-abandons.sql`. Il peut être relancé sans risque.
- Accueil : le bouton « Jouer » cherche un adversaire de votre niveau. Au bout de 10 secondes sans adversaire, « Jouer contre l’ordinateur » est mis en avant.
- Pendant une partie contre l’ordinateur lancée depuis la recherche, le joueur reste disponible. Si quelqu’un le cherche, une bannière lui propose (pendant son tour, 30 secondes pour répondre) de mettre sa partie en pause pour jouer. La partie en pause se reprend depuis l’accueil pendant 6 heures.
- Débutants (moins de 5 parties) : « Jouer » lance une partie contre l’ordinateur ; la recherche reste proposée en lien.
- Or : réglable dans Admin › Économie (victoire et défaite contre l’ordinateur, contre un joueur, bonus de la première victoire du jour contre un joueur, hors plafond). Valeurs par défaut : 6 / 2 contre l’ordinateur, 15 / 5 contre un joueur, bonus de 30. Vos réglages existants sont conservés.
- Toutes les parties comptent toujours pour le classement et les quêtes.

## Cartes à venir (date de sortie)
Exécuter `supabase-cartes-a-venir.sql` une fois (SQL Editor, puis Run), après `supabase-correctif-cartes-saison.sql`. Il peut être relancé sans risque.
- Admin › Cartes › fiche d’une carte › Boosters : champ « Date de sortie ». Avant cette date, la carte n’existe pas pour les joueurs : absente de la collection, de l’éditeur de decks, des paquets, de la fabrication et des decks de l’ordinateur. Elle apparaît d’elle-même le jour venu.
- Dans la liste de l’admin, ces cartes portent la mention « à venir ». Vous pouvez quand même les choisir comme cadeau.
- Après avoir mis une date : « Envoyer le catalogue », puis exporter config.json sur GitHub.
- Différence avec une carte de saison : la carte de saison est visible dans la collection, mais absente des paquets jusqu’à la fin de la saison.

## Statistiques 1 contre 1 du profil
Exécuter `supabase-stats-1v1.sql` une fois (SQL Editor, puis Run), après `supabase-stats.sql`. Il peut être relancé sans risque.
Le profil affiche une section « 1 contre 1 » entre « Statistiques » et « 2 contre 2 » : parties, victoires, victoires contre l’ordinateur et contre un joueur, meilleure série, et résultats par héros.

## Retour dans une partie en ligne
Exécuter `supabase-retour-partie.sql` une fois (SQL Editor, puis Run), après `supabase.sql`. Il peut être relancé sans risque.
Après une déconnexion, tant que la partie en ligne est en cours et a été jouée il y a moins de 6 heures, l’accueil affiche un grand bandeau « Votre partie vous attend ! » avec un bouton pour y revenir (l’hôte reprend la partie, l’invité la rejoint).

## Nouveaux effets de cartes
Dans la fiche d’une carte, 4 nouveaux effets sont disponibles dans chaque bloc d’effet : Défausse, Recyclage, Prophétie et Résurgence. Ils sont pris en compte dans le calcul du budget. Rien à faire dans Supabase.

## Fin de partie par abandon
Exécuter `supabase-fin-partie-abandon.sql` une fois (SQL Editor, puis Run), après `supabase-abandons.sql` et `supabase-retour-partie.sql`. Il peut être relancé sans risque.
- Dès qu’un résultat est enregistré (victoire réclamée après un départ, abandon, fin normale), la partie en ligne est close : plus de bouton « Revenir dans la partie », ni pour le gagnant ni pour le perdant, et l’hôte ne peut plus la reprendre.
- Le joueur déclaré perdant pendant son absence voit à son retour un avis « Partie perdue pendant votre absence », avec la cote perdue. S’il est encore sur l’écran de jeu, la partie s’arrête avec le message de défaite.

## Délai de retour à 45 secondes et tours comptés par manche
Exécuter `supabase-delai-et-tours.sql` une fois (SQL Editor, puis Run), après `supabase-fin-partie-abandon.sql`. Il peut être relancé sans risque.
- Le serveur accorde 45 secondes pour revenir dans une partie classée. Dans l’admin (Règles › minuteur), le champ « Délai pour revenir après une déconnexion » doit indiquer la même valeur : 45.
- En 1 contre 1, un tour = les deux joueurs ont joué le leur (comme en 2 contre 2). Les nouvelles parties sont enregistrées avec ce décompte. Pensez à diviser par 2 le nombre de tours des quêtes « Gagner en moins de N tours ».

## Classement par saison
Exécuter `supabase-classement-saison.sql` une fois (SQL Editor, puis Run), après `supabase-classement.sql` et `supabase-saisons.sql`. Il peut être relancé sans risque.
- À la fin de chaque saison, les joueurs classés en 1 contre 1 qui ont terminé au moins une partie classée pendant la saison reçoivent de l’or par la boîte aux lettres : 1er 200, 2e 100, 3e 50, 4e à 10e 25, 11e à 100e 10. Puis toutes les cotes (1 contre 1 et 2 contre 2) repartent à 1200.
- La clôture se fait toute seule à la première visite d’un joueur après la fin de la saison. Les saisons déjà terminées avant l’installation sont closes sans récompense.
- Pour changer les gains : voir la ligne d’exemple en bas du script (réglage « gains_classement »).

## Invitations à jouer
Exécuter `supabase-invitations.sql` une fois (SQL Editor, puis Run), après `supabase-jouer-entre-joueurs.sql`. Il peut être relancé sans risque.
Tout joueur connecté, sur l’accueil, dans les menus ou en partie contre l’ordinateur, est disponible : quand quelqu’un cherche un adversaire et que personne d’autre ne cherche, il reçoit « X veut vous affronter ! » (« Jouer ! » ou « Non merci »). Il cesse d’être disponible dès que l’onglet du jeu n’est plus affiché.

## Avatar du podium en 2 contre 2

Exécutez `supabase-heros-classement-2v2.sql` dans Supabase (SQL Editor), après `supabase-classement-saison.sql`. Le podium du 2 contre 2 affiche alors le dieu favori de chaque joueur, comme en 1 contre 1.

Dieu retenu, dans les deux modes : le plus joué (panthéon et palier de dévotion). En cas d'égalité, c'est le meilleur taux de victoire avec ce dieu, puis le plus de dégâts infligés, puis le plus de cartes achetées. Aucun changement dans `index.html`.

## Animations : booster, pouvoir divin, récompenses

- **Ouverture de booster** : le sachet se déchire selon un tracé irrégulier, différent à chaque ouverture, parmi 4 types (bande en haut, coin arraché, biais, déchirure qui plonge). Bord de papier blanc, fibres, lueur et miettes de papier.
- **Pouvoir divin** : activation sur tout l'écran, pour les deux joueurs (flash, onde de choc, rayons, tremblement du plateau, bannière avec le portrait du dieu et le nom du pouvoir). En « animations réduites », pas de tremblement ni de rayons.
- **Gains de quêtes et cadeaux** : onde dorée et « +N or » au bouton, pièces (ou gouttes d'encre) qui volent jusqu'à la bourse.
- **Carte ou illustration gagnée** (saison, trophées, boîte aux lettres, cadeaux automatiques) : après « Réclamer », elle part du bouton, tournoie sur elle-même et se pose au milieu de l'écran, avec le halo de sa rareté.

Aucun script Supabase à exécuter pour ces animations.

## Traduction automatique en anglais

Tout ce qui est écrit en français dans l'admin est traduit automatiquement en anglais : cartes, divinités, pouvoirs, saisons, boosters, illustrations, indices, messages, notes de mise à jour, paliers de cadeaux automatiques, texte du don et de la bêta.

- **Quand** : quelques secondes après chaque enregistrement dans l'admin, juste avant l'export de config.json, et à l'envoi d'un message, d'une note ou des paliers (si le champ anglais est vide).
- **Service** : MyMemory, gratuit, sans clé. Le jeu envoie l'adresse e-mail du compte admin, ce qui porte le quota à environ 50 000 caractères par jour. Si le quota est atteint, l'admin l'indique et la suite est traduite plus tard (bouton « Traduire maintenant »).
- **Vérification** : la page Admin › Traductions marque « 🌐 Automatique » chaque traduction faite par la machine. Une traduction corrigée à la main n'est plus jamais écrasée. Les variables comme `{pseudo}` sont conservées.

Aucun script Supabase à exécuter.

## Admin › Animations (banc d'essai)

Une page de l'admin (menu « Le jeu » › Animations) pour déclencher chaque animation sans jouer :

- **Niveau des animations** sur l'appareil : complètes, réduites ou aucune (le même réglage que les joueurs).
- **Ouverture de booster** : choix du paquet (classique, panthéon, booster spécial), du tracé de déchirure et du contenu (tirage normal, avec une épique, une légendaire ou une illustration alternative).
- **Pouvoir divin** de chaque divinité, palier de dévotion compris.
- **Récompenses** : gain de quête, or et encre, paquet offert, carte gagnée, illustration gagnée, ou tout à la fois.
- **Partie de test** contre l'ordinateur : panthéons, divinité, pouvoir chargé, or, puissance, créatures déjà en jeu de chaque côté, cartes choisies dans la main. Elle n'est jamais enregistrée (ni or, ni quêtes, ni statistiques, ni classement). Un bandeau en haut de l'écran ramène à la page Animations.

Rien n'est envoyé au serveur. Aucun script Supabase à exécuter.

## Animations de combat et des menus

**En combat**
- **Écran VS** au lancement de chaque partie (contre l'ordinateur, à deux, en ligne, en 2 contre 2) : portraits des dieux, pseudos et cotes en ligne. La cote de l'invité est transmise à l'hôte au moment où il rejoint la partie.
- **Bannière de tour** avec le portrait du joueur dont c'est le tour et un reflet qui la balaie.
- **Morts aux couleurs du panthéon** : éclats de glace (Nordiques), sable qui s'effrite (Égyptiens), marbre qui se fissure et se brise (Grecs), pétales de lotus (Hindous).
- **Entrée selon la rareté** : une épique tombe avec un petit choc, une légendaire arrive dans une colonne de lumière et fait trembler le plateau.
- **Dégâts** : chiffres d'autant plus gros que le coup est fort (à partir de 3, 6 et 10), plateau qui tremble en proportion.
- **Tension** : sous 10 PV, le portrait bat comme un cœur, et les bords de l'écran rougissent pour votre propre héros.
- **Jauge de pouvoir à 70 % ou plus** : le médaillon crépite.
- **Achat au marché** : les pièces partent de la bourse vers la carte, puis la carte s'envole vers la défausse.
- **Coup fatal** : ralenti et zoom sur le coup, puis une scène de victoire (pluie de lumière, portrait triomphant) ou de défaite (écran qui se fissure, portrait qui s'éteint).

**Hors combat**
- **Cote après une partie classée** : le chiffre défile, le gain ou la perte apparaît, avec les places gagnées et « Top 10 ! » à l'entrée dans les dix premiers.
- **Travail de saison accompli** : sur l'accueil, la barre se remplit puis éclate.
- **Boîte aux lettres** : une enveloppe s'ouvre quand on lit un message avec un cadeau.
- **Accueil vivant** : braises aux couleurs de la saison (en animations complètes seulement).

Tout se teste dans Admin › Animations (rubriques « Combat » et « Menus »). Aucun script Supabase à exécuter.

## Bruitages des nouvelles animations

Admin › Bruitages contient 24 nouveaux emplacements, rangés dans « Combat : nouvelles animations » et « Menus : nouvelles animations » : écran VS, bannière de tour, morts par panthéon, entrées épique et légendaire, gros dégâts, battement de cœur, jauge qui crépite, coup fatal, pouvoir par panthéon, pièces, carte qui tournoie, enveloppe, travail de saison, cote qui monte ou baisse, top 10.

- Chaque emplacement donne une idée de son et une durée conseillée.
- Plusieurs fichiers par emplacement : le jeu en tire un au hasard à chaque fois.
- Emplacement vide : certains utilisent un son existant (indiqué sous l'emplacement, par exemple les morts par panthéon utilisent « Créature détruite »), les autres restent silencieux.
- Pour écouter chaque son avec son animation : Admin › Animations.

Après l'ajout des fichiers, exportez config.json. Aucun script Supabase à exécuter.

### Taille des bruitages

Jusqu'à 1 Mo par fichier (MP3, OGG, WAV ou M4A). Sur le site, chaque son est envoyé dans le stockage Supabase (dossier `sons/` du stockage `images`), et config.json ne garde que son adresse : le jeu reste léger à charger. Le stockage est celui des images, déjà créé par `supabase-images.sql`.
