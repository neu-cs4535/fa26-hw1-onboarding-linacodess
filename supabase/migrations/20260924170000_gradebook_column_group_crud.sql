-- Instructor-facing CRUD for gradebook column groups.
--
-- Storing membership is only half the point: a stored value nobody can edit is just a slower
-- guess. These RPCs are what make the trigger's slug-derived default legitimate, because an
-- instructor can override it.
--
-- RPCs rather than Edge Functions, per the repository's data-access convention: this is plain data
-- manipulation with no external service involved. Every function is SECURITY INVOKER, so the RLS
-- policies on gradebook_column_groups and gradebook_columns are what authorize the caller -- the
-- "instructors CRUD" policy is the single place the permission is expressed.

-- Create a group. Returns the new row so the caller can select it without a second round trip.
create or replace function public.create_gradebook_column_group(
    p_gradebook_id bigint,
    p_name text
)
returns public.gradebook_column_groups
language plpgsql
security invoker
set search_path = public
as $$
declare
    v_class_id bigint;
    v_sort integer;
    v_row public.gradebook_column_groups;
begin
    if p_name is null or btrim(p_name) = '' then
        raise exception 'Group name cannot be empty';
    end if;

    select class_id into v_class_id from public.gradebooks where id = p_gradebook_id;
    if v_class_id is null then
        raise exception 'Gradebook % not found', p_gradebook_id;
    end if;

    select coalesce(max(sort_order), 0) + 1 into v_sort
    from public.gradebook_column_groups where gradebook_id = p_gradebook_id;

    insert into public.gradebook_column_groups (class_id, gradebook_id, name, sort_order)
    values (v_class_id, p_gradebook_id, btrim(p_name), v_sort)
    returning * into v_row;

    return v_row;
end;
$$;

-- Rename a group. The name is rendered verbatim, so it is stored exactly as typed.
create or replace function public.rename_gradebook_column_group(
    p_group_id bigint,
    p_name text
)
returns public.gradebook_column_groups
language plpgsql
security invoker
set search_path = public
as $$
declare
    v_row public.gradebook_column_groups;
begin
    if p_name is null or btrim(p_name) = '' then
        raise exception 'Group name cannot be empty';
    end if;

    update public.gradebook_column_groups
    set name = btrim(p_name)
    where id = p_group_id
    returning * into v_row;

    if v_row.id is null then
        raise exception 'Group % not found, or you do not have permission to rename it', p_group_id;
    end if;

    return v_row;
end;
$$;

-- Delete a group. The columns survive: gradebook_columns.group_id is ON DELETE SET NULL, so they
-- become ungrouped and keep every score attached to them. Deleting a header must never be a way
-- to delete grades.
create or replace function public.delete_gradebook_column_group(p_group_id bigint)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare
    v_deleted bigint;
begin
    delete from public.gradebook_column_groups where id = p_group_id returning id into v_deleted;
    if v_deleted is null then
        raise exception 'Group % not found, or you do not have permission to delete it', p_group_id;
    end if;
end;
$$;

-- Move columns into a group, or out of every group when p_group_id is null.
--
-- This is the operation the whole feature exists for: the slug-derived default the insert trigger
-- applied is a suggestion, and this is how an instructor overrules it.
create or replace function public.set_gradebook_column_group(
    p_column_ids bigint[],
    p_group_id bigint
)
returns integer
language plpgsql
security invoker
set search_path = public
as $$
declare
    v_gradebook_id bigint;
    v_count integer;
begin
    if p_column_ids is null or array_length(p_column_ids, 1) is null then
        return 0;
    end if;

    if p_group_id is not null then
        select gradebook_id into v_gradebook_id
        from public.gradebook_column_groups where id = p_group_id;

        if v_gradebook_id is null then
            raise exception 'Group % not found, or you do not have permission to use it', p_group_id;
        end if;

        -- A column and its group have to belong to the same gradebook, or a header would claim a
        -- column from another course. The RLS policies authorize per class; this guards the
        -- narrower case of two gradebooks a caller can legitimately see both of.
        if exists (
            select 1 from public.gradebook_columns
            where id = any (p_column_ids) and gradebook_id <> v_gradebook_id
        ) then
            raise exception 'Columns must belong to the same gradebook as the group';
        end if;
    end if;

    update public.gradebook_columns
    set group_id = p_group_id
    where id = any (p_column_ids);

    get diagnostics v_count = row_count;

    -- Drop a group the move emptied, so the gradebook does not keep a header with nothing under it.
    delete from public.gradebook_column_groups g
    where not exists (select 1 from public.gradebook_columns c where c.group_id = g.id);

    return v_count;
end;
$$;

-- Reorder groups. Records the instructor's intended left-to-right order.
--
-- Note that the gradebook renders headers in the order of each group's leftmost column, because
-- the manage view is a horizontal table and a header has to sit above its own columns. So the
-- visible effect of reordering groups comes from moving the columns; this records the intent.
create or replace function public.reorder_gradebook_column_groups(p_group_ids bigint[])
returns integer
language plpgsql
security invoker
set search_path = public
as $$
declare
    v_count integer;
begin
    update public.gradebook_column_groups g
    set sort_order = ord.position
    from (
        select unnest(p_group_ids) as id, generate_series(1, array_length(p_group_ids, 1)) as position
    ) ord
    where g.id = ord.id;

    get diagnostics v_count = row_count;
    return v_count;
end;
$$;

comment on function public.create_gradebook_column_group(bigint, text) is
    'Create a gradebook column group. Authorized by the instructors-CRUD RLS policy on the table.';
comment on function public.set_gradebook_column_group(bigint[], bigint) is
    'Move columns into a group, or out of every group when p_group_id is null. Drops groups the move empties.';
