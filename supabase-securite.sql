-- =====================================================================
-- SÉCURITÉ, NIVEAU 1 : le serveur ne fait plus confiance au navigateur
-- À exécuter une fois dans Supabase (SQL Editor, puis Run), après tous les autres scripts.
--   * tickets de partie : récompense et statistiques une seule fois par partie, après une durée minimale
--   * statistiques vérifiées (valeurs plausibles, cartes existantes)
--   * quête du jour calculée par le serveur à partir des parties enregistrées
--   * decks vérifiés (cartes possédées, limites d’exemplaires, taille)
-- =====================================================================

-- Réglages (modifiables ensuite dans la table economie)
update public.economie set reglages = jsonb_build_object('duree_min_partie', 120, 'parties_par_heure', 30, 'taille_deck', 30, 'decks_max', 9) || reglages where id = 1;

-- ---------- 1. Tickets de partie
create table if not exists public.tickets_partie (
  id uuid primary key default gen_random_uuid(),
  hote uuid not null references auth.users(id) on delete cascade,
  invite uuid references auth.users(id) on delete set null,
  mode text not null check (mode in ('ia', 'duo', 'enligne')),
  cree timestamptz not null default now(),
  enregistre boolean not null default false
);
create index if not exists tickets_partie_hote on public.tickets_partie (hote, cree);
alter table public.tickets_partie enable row level security;   -- aucun accès direct : uniquement par les fonctions

create table if not exists public.recompenses_partie (
  ticket uuid not null references public.tickets_partie(id) on delete cascade,
  joueur uuid not null references auth.users(id) on delete cascade,
  gain int not null,
  cree timestamptz not null default now(),
  primary key (ticket, joueur)
);
alter table public.recompenses_partie enable row level security;

create or replace function public.commencer_partie(p_mode text, p_invite uuid default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); t uuid; max_h int := coalesce((reglage('parties_par_heure'))::int, 30);
begin
  if u is null then raise exception 'Connexion requise.'; end if;
  if p_mode not in ('ia', 'duo', 'enligne') then raise exception 'Mode de partie inconnu.'; end if;
  if (select count(*) from tickets_partie where hote = u and cree > now() - interval '1 hour') >= max_h then
    raise exception 'Trop de parties commencées en une heure : patientez un peu.';
  end if;
  if p_mode = 'enligne' then
    if p_invite is null or p_invite = u or not exists (select 1 from profils where id = p_invite) then
      raise exception 'Adversaire en ligne inconnu.';
    end if;
  else
    p_invite := null;
  end if;
  insert into tickets_partie (hote, invite, mode) values (u, p_invite, p_mode) returning id into t;
  return t;
end $$;
grant execute on function public.commencer_partie(text, uuid) to authenticated;

-- ---------- 2. Enregistrement d’une partie : uniquement avec un ticket valide, et des valeurs plausibles
create or replace function public.stats_plausibles(c jsonb) returns boolean
language sql stable set search_path = public as $$
  select jsonb_typeof(c) = 'object'
    and coalesce((c->>'degats')::numeric, 0) between 0 and 2000
    and coalesce((c->>'soins')::numeric, 0) between 0 and 2000
    and coalesce((c->>'creatures')::numeric, 0) between 0 and 300
    and coalesce((c->>'sorts')::numeric, 0) between 0 and 400
    and coalesce((c->>'achats')::numeric, 0) between 0 and 300
    and coalesce((c->>'pouvoirs')::numeric, 0) between 0 and 60
    and (jsonb_typeof(c->'jouees') is distinct from 'object' or not exists (
          select 1 from jsonb_each_text(c->'jouees') e
          where not exists (select 1 from catalogue k where k.carte = e.key) or e.value !~ '^\d{1,3}$'))
    and (jsonb_typeof(c->'achetees') is distinct from 'object' or not exists (
          select 1 from jsonb_each_text(c->'achetees') e
          where not exists (select 1 from catalogue k where k.carte = e.key) or e.value !~ '^\d{1,3}$'))
$$;

create or replace function public.enregistrer_duel(d jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare
  u uuid := auth.uid(); t tickets_partie; c jsonb; i int; typ text; j uuid; duree int;
  v int := case when d->>'vainqueur' in ('0', '1') then (d->>'vainqueur')::int else null end;
  min_s int := coalesce((reglage('duree_min_partie'))::int, 120);
begin
  if u is null then raise exception 'Connexion requise.'; end if;
  if coalesce(d->>'id_partie', '') !~ '^[0-9a-f-]{36}$' then raise exception 'Partie sans ticket : elle ne peut pas être enregistrée.'; end if;
  select * into t from tickets_partie where id = (d->>'id_partie')::uuid and hote = u for update;
  if not found then raise exception 'Ticket de partie inconnu.'; end if;
  if t.enregistre then return; end if;                                  -- déjà enregistrée : rien à faire
  if t.mode <> coalesce(d->>'mode', '') then raise exception 'Le mode ne correspond pas au ticket.'; end if;
  duree := extract(epoch from now() - t.cree)::int;
  if duree < min_s then raise exception 'Partie trop courte pour être enregistrée.'; end if;
  if duree > 6*3600 then raise exception 'Ticket de partie expiré.'; end if;
  if coalesce((d->>'tours')::numeric, 0) not between 1 and 400 then raise exception 'Statistiques invalides.'; end if;
  for i in 0..1 loop
    if not stats_plausibles(d->'cotes'->i) then raise exception 'Statistiques invalides.'; end if;
  end loop;
  for i in 0..1 loop
    c := d->'cotes'->i;
    if t.mode = 'ia' then typ := case when i = 0 then 'joueur' else 'ordinateur' end; j := case when i = 0 then u end;
    elsif t.mode = 'duo' then typ := 'local'; j := null;
    else typ := case when i = 0 then 'joueur' else 'invite' end; j := case when i = 0 then u else t.invite end;   -- l’invité vient du ticket, pas du navigateur
    end if;
    insert into parties_jouees (id_partie, place, cote, joueur, enregistre_par, mode, victoire, egalite, tours, duree_s,
                                heros, heros_adverse, degats, soins, creatures, sorts, achats, pouvoirs, jouees, achetees)
    values (t.id::text, i, typ, j, u, t.mode, v is not null and v = i, v is null, borne(d->>'tours', 400), duree,
            left(c->>'heros', 30), left(d->'cotes'->(1-i)->>'heros', 30),
            borne(c->>'degats', 2000), borne(c->>'soins', 2000), borne(c->>'creatures', 300),
            borne(c->>'sorts', 400), borne(c->>'achats', 300), borne(c->>'pouvoirs', 60),
            case when jsonb_typeof(c->'jouees') = 'object' then c->'jouees' else '{}'::jsonb end,
            case when jsonb_typeof(c->'achetees') = 'object' then c->'achetees' else '{}'::jsonb end)
    on conflict (id_partie, place) do nothing;
  end loop;
  update tickets_partie set enregistre = true where id = t.id;
end $$;

-- ---------- 3. Récompense : une seule par joueur et par ticket, d’après la partie enregistrée par le serveur
create or replace function public.fin_partie(victoire boolean) returns int
language plpgsql security definer set search_path = public as $$
begin raise exception 'Version du jeu obsolète : rechargez la page.'; end $$;

create or replace function public.fin_partie_ticket(p_ticket uuid) returns int
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); t tickets_partie; p profils; gain int; vict boolean;
        plafond int := coalesce((reglage('plafond_or_jour'))::int, 100);
begin
  if u is null then raise exception 'Connexion requise.'; end if;
  select * into t from tickets_partie where id = p_ticket and (hote = u or invite = u) and mode in ('ia', 'enligne');
  if not found then raise exception 'Ticket de partie inconnu.'; end if;
  if exists (select 1 from recompenses_partie where ticket = p_ticket and joueur = u) then raise exception 'Récompense déjà obtenue pour cette partie.'; end if;
  select pj.victoire into vict from parties_jouees pj where pj.id_partie = p_ticket::text and pj.joueur = u;
  if not found then raise exception 'Partie pas encore enregistrée.'; end if;
  select * into p from profils where id = u for update;
  if p.jour is distinct from current_date then p.or_jour := 0; end if;
  gain := case when vict then (reglage('or_victoire'))::int else (reglage('or_defaite'))::int end;
  gain := greatest(0, least(gain, plafond - p.or_jour));
  update profils set pieces_or = pieces_or + gain, or_jour = p.or_jour + gain, jour = current_date where id = u;
  insert into recompenses_partie (ticket, joueur, gain) values (p_ticket, u, gain);
  return gain;
end $$;
grant execute on function public.fin_partie_ticket(uuid) to authenticated;

-- ---------- 4. Quête du jour : choisie et vérifiée par le serveur
create or replace function public.mes_quete() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare u uuid := auth.uid(); q jsonb; liste jsonb := '[
  {"texte":"Jouer 10 créatures","cle":"creatures","but":10},
  {"texte":"Acheter 8 cartes au marché","cle":"achats","but":8},
  {"texte":"Infliger 40 dégâts à l’adversaire","cle":"degats","but":40},
  {"texte":"Gagner 2 parties","cle":"victoires","but":2},
  {"texte":"Jouer 3 parties","cle":"parties","but":3},
  {"texte":"Jouer 15 sorts","cle":"sorts","but":15}]'::jsonb;
  pr jsonb;
begin
  q := liste -> ((current_date - date '1970-01-01') % jsonb_array_length(liste));
  select jsonb_build_object('creatures', coalesce(sum(creatures), 0), 'achats', coalesce(sum(achats), 0), 'degats', coalesce(sum(degats), 0),
                            'sorts', coalesce(sum(sorts), 0), 'parties', count(*), 'victoires', count(*) filter (where victoire))
    into pr from parties_jouees where joueur = u and mode in ('ia', 'enligne') and cree::date = current_date;
  return q || jsonb_build_object('progres', least((pr ->> (q->>'cle'))::int, (q->>'but')::int),
                                 'faite', (select quete_jour = current_date from profils where id = u));
end $$;
grant execute on function public.mes_quete() to authenticated;

create or replace function public.reclamer_quete() returns int
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); q jsonb := mes_quete(); gain int := coalesce((reglage('or_quete'))::int, 40);
begin
  if (q->>'progres')::int < (q->>'but')::int then raise exception 'La quête du jour n’est pas encore terminée.'; end if;
  update profils set pieces_or = pieces_or + gain, quete_jour = current_date where id = u and quete_jour is distinct from current_date;
  if not found then raise exception 'La quête du jour a déjà été récompensée.'; end if;
  return gain;
end $$;

-- ---------- 5. Decks vérifiés par le serveur
create or replace function public.verifier_cartes_deck(p_joueur uuid, p_cartes jsonb) returns text
language plpgsql stable security definer set search_path = public as $$
declare r record; taille int := coalesce((reglage('taille_deck'))::int, 30);
        v_max int := coalesce((reglage('copies_max'))::int, 2); v_leg int := coalesce((reglage('copies_legendaire'))::int, 1);
begin
  if jsonb_typeof(p_cartes) <> 'array' then return 'Format de deck invalide.'; end if;
  if jsonb_array_length(p_cartes) > taille then return 'Un deck contient au maximum ' || taille || ' cartes.'; end if;
  if exists (select 1 from jsonb_array_elements(p_cartes) e where jsonb_typeof(e) <> 'string') then return 'Format de deck invalide.'; end if;
  for r in select e #>> '{}' as carte, count(*) as n from jsonb_array_elements(p_cartes) e group by 1 loop
    if not exists (select 1 from catalogue where carte = r.carte and achetable) then return 'Carte non autorisée dans un deck : ' || r.carte || '.'; end if;
    if r.n > (select case when rarete = 'legendaire' then v_leg else v_max end from catalogue where carte = r.carte) then
      return 'Trop d’exemplaires de ' || r.carte || '.';
    end if;
    if r.n > coalesce((select nb from collection where joueur = p_joueur and carte = r.carte), 0) then
      return 'Carte non possédée en nombre suffisant : ' || r.carte || '.';
    end if;
  end loop;
  return null;
end $$;

create or replace function public.controle_deck() returns trigger
language plpgsql security definer set search_path = public as $$
declare msg text;
begin
  new.joueur := coalesce(new.joueur, auth.uid());
  if auth.uid() is not null and new.joueur <> auth.uid() then raise exception 'Deck d’un autre joueur.'; end if;
  msg := verifier_cartes_deck(new.joueur, new.cartes);
  if msg is not null then raise exception '%', msg; end if;
  if tg_op = 'INSERT' and (select count(*) from decks where joueur = new.joueur) >= coalesce((reglage('decks_max'))::int, 9) then
    raise exception 'Nombre maximum de decks atteint.';
  end if;
  new.nom := left(coalesce(nullif(btrim(new.nom), ''), 'Deck sans nom'), 40);
  return new;
end $$;
drop trigger if exists decks_controle on public.decks;
create trigger decks_controle before insert or update on public.decks for each row execute function public.controle_deck();

-- Partie en ligne : l’hôte vérifie que le deck envoyé par l’invité est légal et possédé (réponse oui / non seulement)
create or replace function public.deck_invite_valide(p_invite uuid, p_cartes jsonb) returns boolean
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then return false; end if;
  return jsonb_typeof(p_cartes) = 'array' and jsonb_array_length(p_cartes) > 0 and verifier_cartes_deck(p_invite, p_cartes) is null;
end $$;
grant execute on function public.deck_invite_valide(uuid, jsonb) to authenticated;

revoke execute on function public.verifier_cartes_deck(uuid, jsonb) from public, anon, authenticated;
revoke execute on function public.stats_plausibles(jsonb) from public, anon, authenticated;
