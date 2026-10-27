-- =====================================================================
-- SURVEILLANCE : journal des tentatives suspectes et comportements inhabituels
-- À exécuter une fois dans Supabase (SQL Editor, puis Run), après supabase-securite.sql.
-- Les fonctions sensibles renvoient désormais un refus (au lieu d’une erreur) pour que
-- l’alerte soit conservée : une erreur annulerait aussi l’écriture dans le journal.
-- =====================================================================

create table if not exists public.alertes (
  id bigint generated always as identity primary key,
  joueur uuid references auth.users(id) on delete cascade,
  motif text not null,
  gravite text not null check (gravite in ('faible', 'moyenne', 'forte')),
  details jsonb not null default '{}'::jsonb,
  compteur int not null default 1,
  jour date not null default current_date,
  premiere timestamptz not null default now(),
  derniere timestamptz not null default now(),
  traite boolean not null default false,
  unique (joueur, motif, jour)
);
alter table public.alertes enable row level security;   -- lecture uniquement par les fonctions d’administration

-- Enregistre (ou regroupe) une alerte : même joueur, même motif, même jour = compteur + 1
create or replace function public.noter_alerte(p_joueur uuid, p_motif text, p_gravite text, p_details jsonb) returns void
language sql security definer set search_path = public as $$
  insert into alertes (joueur, motif, gravite, details) values (p_joueur, p_motif, p_gravite, coalesce(p_details, '{}'::jsonb))
  on conflict (joueur, motif, jour) do update
    set compteur = alertes.compteur + 1, derniere = now(), details = excluded.details, traite = false
$$;
revoke execute on function public.noter_alerte(uuid, text, text, jsonb) from public, anon, authenticated;

-- ---------- Ouverture d’une partie : renvoie le ticket, ou null si refusée
drop function if exists public.commencer_partie(text, uuid);
create or replace function public.commencer_partie(p_mode text, p_invite uuid default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); t uuid; max_h int := coalesce((reglage('parties_par_heure'))::int, 30); n int;
begin
  if u is null then return null; end if;
  if p_mode not in ('ia', 'duo', 'enligne') then perform noter_alerte(u, 'mode_inconnu', 'forte', jsonb_build_object('mode', p_mode)); return null; end if;
  n := (select count(*) from tickets_partie where hote = u and cree > now() - interval '1 hour');
  if n >= max_h then perform noter_alerte(u, 'trop_de_parties', 'moyenne', jsonb_build_object('parties_en_une_heure', n, 'limite', max_h)); return null; end if;
  if p_mode = 'enligne' then
    if p_invite is null or p_invite = u or not exists (select 1 from profils where id = p_invite) then
      perform noter_alerte(u, 'adversaire_invente', 'forte', jsonb_build_object('invite', p_invite)); return null;
    end if;
  else p_invite := null; end if;
  insert into tickets_partie (hote, invite, mode) values (u, p_invite, p_mode) returning id into t;
  return t;
end $$;
grant execute on function public.commencer_partie(text, uuid) to authenticated;

-- ---------- Enregistrement d’une partie : renvoie null si accepté, sinon le motif du refus
drop function if exists public.enregistrer_duel(jsonb);
create or replace function public.enregistrer_duel(d jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare
  u uuid := auth.uid(); t tickets_partie; c jsonb; i int; typ text; j uuid; duree int;
  v int := case when d->>'vainqueur' in ('0', '1') then (d->>'vainqueur')::int else null end;
  min_s int := coalesce((reglage('duree_min_partie'))::int, 120);
begin
  if u is null then return 'Connexion requise.'; end if;
  if coalesce(d->>'id_partie', '') !~ '^[0-9a-f-]{36}$' then
    perform noter_alerte(u, 'partie_sans_ticket', 'forte', jsonb_build_object('identifiant_envoye', left(d->>'id_partie', 60))); return 'Ticket de partie inconnu.';
  end if;
  select * into t from tickets_partie where id = (d->>'id_partie')::uuid and hote = u for update;
  if not found then perform noter_alerte(u, 'ticket_invente', 'forte', jsonb_build_object('ticket', d->>'id_partie')); return 'Ticket de partie inconnu.'; end if;
  if t.enregistre then return null; end if;
  if t.mode <> coalesce(d->>'mode', '') then
    perform noter_alerte(u, 'mode_falsifie', 'forte', jsonb_build_object('mode_du_ticket', t.mode, 'mode_envoye', d->>'mode')); return 'Le mode ne correspond pas au ticket.';
  end if;
  duree := extract(epoch from now() - t.cree)::int;
  if duree < min_s then
    perform noter_alerte(u, 'partie_trop_courte', 'moyenne', jsonb_build_object('duree_s', duree, 'minimum_s', min_s, 'mode', t.mode, 'tours_declares', d->>'tours'));
    return 'Partie trop courte pour être enregistrée.';
  end if;
  if duree > 6*3600 then return 'Ticket de partie expiré.'; end if;
  if coalesce((d->>'tours')::numeric, 0) not between 1 and 400 or not stats_plausibles(d->'cotes'->0) or not stats_plausibles(d->'cotes'->1) then
    perform noter_alerte(u, 'statistiques_impossibles', 'forte', jsonb_build_object('mode', t.mode, 'tours', d->>'tours', 'camp_joueur', d->'cotes'->0, 'camp_adverse', d->'cotes'->1));
    return 'Statistiques invalides.';
  end if;
  for i in 0..1 loop
    c := d->'cotes'->i;
    if t.mode = 'ia' then typ := case when i = 0 then 'joueur' else 'ordinateur' end; j := case when i = 0 then u end;
    elsif t.mode = 'duo' then typ := 'local'; j := null;
    else typ := case when i = 0 then 'joueur' else 'invite' end; j := case when i = 0 then u else t.invite end;
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
  return null;
end $$;
grant execute on function public.enregistrer_duel(jsonb) to authenticated;

-- ---------- Récompense : renvoie {"gain": n} ou {"erreur": "..."}
create or replace function public.fin_partie(victoire boolean) returns int
language plpgsql security definer set search_path = public as $$
begin
  perform noter_alerte(auth.uid(), 'ancienne_version', 'faible', jsonb_build_object('victoire_declaree', victoire));
  return 0;
end $$;

drop function if exists public.fin_partie_ticket(uuid);
create or replace function public.fin_partie_ticket(p_ticket uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); t tickets_partie; p profils; gain int; vict boolean;
        plafond int := coalesce((reglage('plafond_or_jour'))::int, 100);
begin
  if u is null then return jsonb_build_object('erreur', 'Connexion requise.'); end if;
  select * into t from tickets_partie where id = p_ticket and (hote = u or invite = u) and mode in ('ia', 'enligne');
  if not found then
    perform noter_alerte(u, 'recompense_sans_partie', 'forte', jsonb_build_object('ticket', p_ticket, 'ticket_d_un_autre_joueur', exists (select 1 from tickets_partie where id = p_ticket)));
    return jsonb_build_object('erreur', 'Ticket de partie inconnu.');
  end if;
  if exists (select 1 from recompenses_partie where ticket = p_ticket and joueur = u) then
    perform noter_alerte(u, 'double_recompense', 'faible', jsonb_build_object('ticket', p_ticket));
    return jsonb_build_object('erreur', 'Récompense déjà obtenue pour cette partie.');
  end if;
  select pj.victoire into vict from parties_jouees pj where pj.id_partie = p_ticket::text and pj.joueur = u;
  if not found then return jsonb_build_object('erreur', 'Partie pas encore enregistrée.'); end if;
  select * into p from profils where id = u for update;
  if p.jour is distinct from current_date then p.or_jour := 0; end if;
  gain := case when vict then (reglage('or_victoire'))::int else (reglage('or_defaite'))::int end;
  gain := greatest(0, least(gain, plafond - p.or_jour));
  update profils set pieces_or = pieces_or + gain, or_jour = p.or_jour + gain, jour = current_date where id = u;
  insert into recompenses_partie (ticket, joueur, gain) values (p_ticket, u, gain);
  return jsonb_build_object('gain', gain);
end $$;
grant execute on function public.fin_partie_ticket(uuid) to authenticated;

-- ---------- Quête : renvoie le gain, -1 si la quête n’est pas finie, -2 si déjà récompensée
create or replace function public.reclamer_quete() returns int
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); q jsonb := mes_quete(); gain int := coalesce((reglage('or_quete'))::int, 40);
begin
  if (q->>'progres')::int < (q->>'but')::int then
    perform noter_alerte(u, 'quete_non_terminee', 'forte', jsonb_build_object('quete', q->>'texte', 'progres', q->'progres', 'objectif', q->'but'));
    return -1;
  end if;
  update profils set pieces_or = pieces_or + gain, quete_jour = current_date where id = u and quete_jour is distinct from current_date;
  if not found then perform noter_alerte(u, 'quete_deja_recompensee', 'faible', '{}'::jsonb); return -2; end if;
  return gain;
end $$;

-- ---------- Decks : enregistrement par le serveur uniquement (renvoie {"id": ...} ou {"erreur": ...})
drop policy if exists decks_cree on public.decks;
drop policy if exists decks_modifie on public.decks;
create or replace function public.sauver_deck(p_id uuid, p_nom text, p_cartes jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); msg text; nid uuid;
begin
  if u is null then return jsonb_build_object('erreur', 'Connexion requise.'); end if;
  msg := verifier_cartes_deck(u, p_cartes);
  if msg is not null then
    perform noter_alerte(u, 'deck_illegal', 'forte', jsonb_build_object('refus', msg, 'nb_cartes', case when jsonb_typeof(p_cartes) = 'array' then jsonb_array_length(p_cartes) end));
    return jsonb_build_object('erreur', msg);
  end if;
  if p_id is null then
    if (select count(*) from decks where joueur = u) >= coalesce((reglage('decks_max'))::int, 9) then return jsonb_build_object('erreur', 'Nombre maximum de decks atteint.'); end if;
    insert into decks (joueur, nom, cartes) values (u, p_nom, p_cartes) returning id into nid;
  else
    update decks set nom = p_nom, cartes = p_cartes, maj = now() where id = p_id and joueur = u returning id into nid;
    if nid is null then perform noter_alerte(u, 'deck_d_un_autre', 'forte', jsonb_build_object('deck', p_id)); return jsonb_build_object('erreur', 'Deck introuvable.'); end if;
  end if;
  return jsonb_build_object('id', nid);
end $$;
grant execute on function public.sauver_deck(uuid, text, jsonb) to authenticated;

-- ---------- En ligne : deck de l’invité refusé = alerte au nom de l’invité
create or replace function public.deck_invite_valide(p_invite uuid, p_cartes jsonb) returns boolean
language plpgsql security definer set search_path = public as $$
declare msg text;
begin
  if auth.uid() is null then return false; end if;
  if jsonb_typeof(p_cartes) <> 'array' or jsonb_array_length(p_cartes) = 0 then return false; end if;
  msg := verifier_cartes_deck(p_invite, p_cartes);
  if msg is not null then
    perform noter_alerte(p_invite, 'deck_illegal_en_ligne', 'forte', jsonb_build_object('refus', msg, 'hote', auth.uid(), 'pseudo_hote', (select pseudo from profils where id = auth.uid())));
    return false;
  end if;
  return true;
end $$;

-- ---------- Administration : alertes et comportements inhabituels
create or replace function public.admin_surveillance(p_jours int default 30) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not est_admin() then raise exception 'Réservé à l’administrateur.'; end if;
  return jsonb_build_object(
    'alertes', (select coalesce(jsonb_agg(to_jsonb(x) order by x.derniere desc), '[]'::jsonb) from (
       select a.*, p.pseudo, u.email from alertes a left join profils p on p.id = a.joueur left join auth.users u on u.id = a.joueur
       where a.derniere > now() - make_interval(days => p_jours)) x),
    'joueurs', (select coalesce(jsonb_object_agg(x.id, to_jsonb(x)), '{}'::jsonb) from (
       select p.id, p.pseudo, u.email, p.pieces_or, p.encre, p.cree, p.derniere_vue,
              (select count(*) from parties_jouees j where j.joueur = p.id) parties,
              (select count(*) from parties_jouees j where j.joueur = p.id and j.victoire) victoires,
              (select count(*) from alertes a where a.joueur = p.id) nb_alertes
       from profils p left join auth.users u on u.id = p.id
       where p.id in (select joueur from alertes) or p.id in (select joueur from parties_jouees where joueur is not null)) x),
    'comportements', (
      with pj as (select * from parties_jouees where joueur is not null and mode in ('ia', 'enligne') and cree > now() - make_interval(days => p_jours)),
      par as (select joueur, count(*) n, count(*) filter (where victoire) v,
                     count(*) filter (where mode = 'ia') n_ia, count(*) filter (where mode = 'ia' and victoire) v_ia,
                     count(*) filter (where cree > now() - interval '24 hours') n24,
                     percentile_cont(0.5) within group (order by duree_s) duree_med, avg(degats) deg_moy, avg(tours) tours_moy
              from pj group by joueur),
      duos as (select least(a.joueur, b.joueur) j1, greatest(a.joueur, b.joueur) j2, count(*) n,
                      count(*) filter (where a.victoire and a.joueur = least(a.joueur, b.joueur)) v1
               from pj a join pj b on a.id_partie = b.id_partie and a.place = 0 and b.place = 1 where a.mode = 'enligne' group by 1, 2),
      c as (
        select joueur, 'Taux de victoire contre l’ordinateur anormalement élevé' motif, 'moyenne' gravite,
               jsonb_build_object('victoires', v_ia, 'parties', n_ia, 'taux', round(100.0*v_ia/n_ia)) details from par where n_ia >= 20 and v_ia >= 0.9*n_ia
        union all
        select joueur, 'Nombre de parties très élevé en 24 heures', 'moyenne', jsonb_build_object('parties_24h', n24) from par where n24 >= 25
        union all
        select joueur, 'Parties anormalement courtes', 'moyenne', jsonb_build_object('duree_mediane_s', round(duree_med::numeric), 'parties', n) from par where n >= 10 and duree_med < 200
        union all
        select joueur, 'Dégâts moyens très élevés', 'faible', jsonb_build_object('degats_moyens', round(deg_moy), 'parties', n) from par where n >= 5 and deg_moy > 120
        union all
        select case when v1 >= n/2.0 then j1 else j2 end, 'Possible arrangement entre deux joueurs en ligne', 'moyenne',
               jsonb_build_object('parties_ensemble', n, 'victoires_du_meme_joueur', greatest(v1, n - v1),
                                  'adversaire', (select coalesce(pseudo, id::text) from profils where id = case when v1 >= n/2.0 then j2 else j1 end))
        from duos where n >= 5 and greatest(v1, n - v1) >= 0.9*n
      )
      select coalesce(jsonb_agg(jsonb_build_object('joueur', c.joueur, 'pseudo', p.pseudo, 'email', u.email, 'motif', c.motif, 'gravite', c.gravite, 'details', c.details)), '[]'::jsonb)
      from c left join profils p on p.id = c.joueur left join auth.users u on u.id = c.joueur)
  );
end $$;

create or replace function public.admin_traiter_alerte(p_id bigint, p_traite boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not est_admin() then raise exception 'Réservé à l’administrateur.'; end if;
  update alertes set traite = p_traite where id = p_id;
end $$;
grant execute on function public.admin_surveillance(int) to authenticated;
grant execute on function public.admin_traiter_alerte(bigint, boolean) to authenticated;
