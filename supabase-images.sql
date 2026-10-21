-- Stockage des images du jeu (cartes en haute définition, héros).
-- À exécuter une fois dans Supabase (SQL Editor, puis Run), après supabase-admin.sql.

-- Dossier public « images » : tout le monde peut voir les images du jeu.
insert into storage.buckets (id, name, public)
values ('images', 'images', true)
on conflict (id) do update set public = true;

-- Seul l'administrateur peut ajouter, remplacer ou supprimer des images.
drop policy if exists "images_admin_ajout" on storage.objects;
drop policy if exists "images_admin_modif" on storage.objects;
drop policy if exists "images_admin_suppr" on storage.objects;
create policy "images_admin_ajout" on storage.objects for insert to authenticated
  with check (bucket_id = 'images' and public.est_admin());
create policy "images_admin_modif" on storage.objects for update to authenticated
  using (bucket_id = 'images' and public.est_admin()) with check (bucket_id = 'images' and public.est_admin());
create policy "images_admin_suppr" on storage.objects for delete to authenticated
  using (bucket_id = 'images' and public.est_admin());
