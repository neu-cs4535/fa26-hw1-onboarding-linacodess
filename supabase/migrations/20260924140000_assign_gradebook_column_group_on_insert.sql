-- Assign a group to gradebook columns created after the backfill.
--
-- The backfill in 20260924090000 groups the columns that existed when it ran. Anything created
-- afterwards -- a new assignment, a new manual column, a course seeded into a fresh database --
-- is inserted with group_id NULL and renders ungrouped. That is not a local-only problem: the
-- gradebook E2E workflow runs migrations against an empty database and seeds the course
-- afterwards, so without this trigger the whole gradebook would come out with no headers at all.
--
-- The rules here are the corrected ones from the backfill's phase 2, not the slug heuristic this
-- feature replaced. A new column is filed by what it is, and the instructor can move it afterwards
-- through the group CRUD -- the point of storing membership is that this default is editable.

create or replace function public.gradebook_column_group_name_for_slug(p_slug text)
returns text
language sql
immutable
as $$
    -- Names are stored and rendered verbatim, so the plural belongs here rather than in a
    -- pluralize() call at render time. A new quiz has to resolve to "Quizzes", not "Quiz", or it
    -- would create a singular twin of the group it belongs in.
    select case
        -- Families whose slugs share no first word, so a prefix rule cannot see them.
        when p_slug like 'ai-usage-log-%' then 'AI Usage Logs'
        when p_slug in ('meets-expectations', 'approaching-expectations', 'does-not-meet-expectations')
            then 'Skills'
        when p_slug in ('average.hw', 'labs-drop-lowest', 'total-labs',
                        'curve-adjustment', 'midterm-standing', 'attendance', 'final')
            then 'Overall'
        when p_slug = 'assignment-final' then 'Projects'

        -- assignment-<type>-<n>: the type is the group.
        when split_part(p_slug, '-', 1) = 'assignment'
             and array_length(string_to_array(p_slug, '-'), 1) >= 3
            then public.gradebook_column_group_pluralise(split_part(p_slug, '-', 2))

        -- assignment-<name>: name it after <name>, rather than filing it under "Assignment" the
        -- way the old heuristic's >= 3 test did.
        when split_part(p_slug, '-', 1) = 'assignment'
             and array_length(string_to_array(p_slug, '-'), 1) = 2
            then public.gradebook_column_group_pluralise(split_part(p_slug, '-', 2))

        when split_part(p_slug, '-', 1) = '' then 'Other'
        else public.gradebook_column_group_pluralise(split_part(p_slug, '-', 1))
    end;
$$;

comment on function public.gradebook_column_group_name_for_slug(text) is
    'Default group name for a gradebook column slug. Used to file newly created columns; instructors can reassign afterwards.';

create or replace function public.assign_gradebook_column_group()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    v_name text;
    v_group_id bigint;
    v_sort integer;
begin
    -- An explicit group wins: the CRUD paths set group_id themselves.
    if new.group_id is not null then
        return new;
    end if;

    v_name := public.gradebook_column_group_name_for_slug(new.slug);
    if v_name is null or v_name = '' then
        return new;
    end if;

    select id into v_group_id
    from public.gradebook_column_groups
    where gradebook_id = new.gradebook_id and name = v_name
    limit 1;

    if v_group_id is null then
        select coalesce(max(sort_order), 0) + 1 into v_sort
        from public.gradebook_column_groups
        where gradebook_id = new.gradebook_id;

        insert into public.gradebook_column_groups (class_id, gradebook_id, name, sort_order)
        values (new.class_id, new.gradebook_id, v_name, coalesce(v_sort, 1))
        returning id into v_group_id;
    end if;

    new.group_id := v_group_id;
    return new;
end;
$$;

-- BEFORE INSERT so the value is written with the row rather than as a second write.
create trigger assign_gradebook_column_group_trigger
    before insert on public.gradebook_columns
    for each row
    execute function public.assign_gradebook_column_group();

-- Catch up anything inserted between the backfill and this trigger.
do $$
declare
    r record;
    v_name text;
    v_group_id bigint;
    v_sort integer;
begin
    for r in
        select id, slug, class_id, gradebook_id
        from public.gradebook_columns
        where group_id is null
        order by gradebook_id, coalesce(sort_order, 0)
    loop
        v_name := public.gradebook_column_group_name_for_slug(r.slug);
        continue when v_name is null or v_name = '';

        select id into v_group_id
        from public.gradebook_column_groups
        where gradebook_id = r.gradebook_id and name = v_name
        limit 1;

        if v_group_id is null then
            select coalesce(max(sort_order), 0) + 1 into v_sort
            from public.gradebook_column_groups
            where gradebook_id = r.gradebook_id;

            insert into public.gradebook_column_groups (class_id, gradebook_id, name, sort_order)
            values (r.class_id, r.gradebook_id, v_name, coalesce(v_sort, 1))
            returning id into v_group_id;
        end if;

        update public.gradebook_columns set group_id = v_group_id where id = r.id;
    end loop;
end $$;
