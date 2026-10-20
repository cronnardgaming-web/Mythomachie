-- Script à exécuter une seule fois dans Supabase (SQL Editor, puis Run).
-- Il crée la table qui sauvegarde les parties en ligne, pour pouvoir les reprendre.

create table if not exists public.parties (
  code    text primary key,
  hote    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  invite  uuid,
  statut  text not null default 'attente',
  etat    jsonb,
  config  jsonb,
  maj     timestamptz not null default now()
);

-- Sécurité : chaque hôte ne voit et ne modifie que ses propres parties.
alter table public.parties enable row level security;

drop policy if exists "hote_lit" on public.parties;
drop policy if exists "hote_cree" on public.parties;
drop policy if exists "hote_modifie" on public.parties;
drop policy if exists "hote_supprime" on public.parties;

create policy "hote_lit" on public.parties
  for select to authenticated using (hote = auth.uid());
create policy "hote_cree" on public.parties
  for insert to authenticated with check (hote = auth.uid());
create policy "hote_modifie" on public.parties
  for update to authenticated using (hote = auth.uid()) with check (hote = auth.uid());
create policy "hote_supprime" on public.parties
  for delete to authenticated using (hote = auth.uid());
