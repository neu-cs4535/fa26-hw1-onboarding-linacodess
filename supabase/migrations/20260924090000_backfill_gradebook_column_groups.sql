-- Backfill gradebook_column_groups for every gradebook that already exists.
--
-- Runs in two phases, deliberately separated so a reviewer can tell reproduction from correction:
--
--   Phase 1 reproduces the render-time heuristic in gradebookTable.tsx (lines 2567-2589) exactly,
--           including the cases it gets wrong. After phase 1 the gradebook renders identically to
--           how it rendered before this feature existed.
--   Phase 2 applies the corrections documented in the design writeup, each as its own labelled
--           statement.
--
-- The constraint that forbids duplicate group names is added at the very end, once phase 2 has
-- removed the duplicates phase 1 legitimately created.
--
-- This is a backfill, not a re-seed: it fills the new column on rows that already exist and must
-- run unchanged against production data, where the gradebook columns belong to real courses.

-- Capitalise and pluralise a slug token for use as a default group name. Only the endings the
-- gradebook's own slugs use are handled; a name an instructor types is stored exactly as typed.
create or replace function public.gradebook_column_group_pluralise(p_word text)
returns text
language sql
immutable
as $$
    select case
        when p_word = '' or p_word is null then p_word
        -- A single z after a vowel doubles: quiz -> quizzes.
        when right(p_word, 1) = 'z' and right(p_word, 2) <> 'zz'
            then upper(left(p_word, 1)) || substring(p_word from 2) || 'zes'
        when right(p_word, 1) in ('s', 'x', 'z') or right(p_word, 2) in ('ch', 'sh')
            then upper(left(p_word, 1)) || substring(p_word from 2) || 'es'
        when right(p_word, 1) = 'y' and right(p_word, 2) not in ('ay', 'ey', 'iy', 'oy', 'uy')
            then upper(left(p_word, 1)) || substring(p_word from 2 for length(p_word) - 2) || 'ies'
        else upper(left(p_word, 1)) || substring(p_word from 2) || 's'
    end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Phase 1 -- reproduce today's grouping exactly.
-- ---------------------------------------------------------------------------------------------

with
-- Step 1: the slug rule. `assignment-<type>-<n>` keeps two slug parts; everything else keeps one.
-- The >= 3 test is the heuristic's own (line 2571), and is the reason `assignment-final` -- two
-- parts -- falls through to the bare prefix `assignment`.
base as (
    select
        c.id,
        c.gradebook_id,
        c.class_id,
        coalesce(c.sort_order, 0) as sort_order,
        case
            when split_part(c.slug, '-', 1) = 'assignment'
                 and array_length(string_to_array(c.slug, '-'), 1) >= 3
                then 'assignment-' || split_part(c.slug, '-', 2)
            when split_part(c.slug, '-', 1) = '' then 'other'
            else split_part(c.slug, '-', 1)
        end as base_name
    from public.gradebook_columns c
),
-- Step 2: the contiguity rule. The heuristic walks columns in sort_order and starts a new group
-- whenever the slug prefix changes OR the sort_order skips a value (lines 2581 and 2584). The
-- comparison is against the immediately preceding column, not the previous column of the same
-- prefix -- which is why a hole in sort_order splits one prefix into two groups.
marked as (
    select
        b.*,
        case
            when lag(b.sort_order) over w is null then 1
            when b.sort_order <> lag(b.sort_order) over w + 1 then 1
            when b.base_name <> lag(b.base_name) over w then 1
            else 0
        end as starts_group
    from base b
    window w as (partition by b.gradebook_id order by b.sort_order)
),
numbered as (
    select
        m.*,
        sum(m.starts_group) over (
            partition by m.gradebook_id
            order by m.sort_order
            rows between unbounded preceding and current row
        ) as group_index
    from marked m
),
-- Step 3: the display name (lines 2589-2603). `other` is capitalised as a word; an
-- `assignment-<type>` base shows only <type>; anything else is the prefix with a capital letter.
named as (
    select
        n.*,
        case
            when n.base_name = 'other' then 'Other'
            when n.base_name like 'assignment-%' then
                upper(left(split_part(n.base_name, '-', 2), 1))
                || substring(split_part(n.base_name, '-', 2) from 2)
            else upper(left(n.base_name, 1)) || substring(n.base_name from 2)
        end as display_name
    from numbered n
),
-- Step 4: create one group row per distinct (gradebook, group_index).
inserted as (
    insert into public.gradebook_column_groups (class_id, gradebook_id, name, sort_order)
    select distinct on (n.gradebook_id, n.group_index)
        n.class_id,
        n.gradebook_id,
        n.display_name,
        n.group_index
    from named n
    order by n.gradebook_id, n.group_index, n.sort_order
    returning id, gradebook_id, sort_order as group_index
)
-- Step 5: point every column at the group its index maps to.
update public.gradebook_columns c
set group_id = i.id
from named n
join inserted i
  on i.gradebook_id = n.gradebook_id
 and i.group_index = n.group_index
where c.id = n.id;

-- ---------------------------------------------------------------------------------------------
-- Phase 2 -- documented corrections.
--
-- Corrections 1 and 2 are general rules: they follow from the heuristic's own logic and apply to
-- any course. Correction 3 is an explicit list keyed on the slug conventions this schema already
-- uses; courses that do not use those slugs keep their phase 1 grouping, and an instructor can
-- adjust any of it afterwards through the group CRUD.
-- ---------------------------------------------------------------------------------------------

-- Name normalisation, before any correction.
--
-- The heuristic capitalised a slug token ("lab" -> "Lab") and both gradebook views then ran that
-- through pluralize() at render time to produce "Labs". The views now render the stored name
-- verbatim -- rewriting a name an instructor chose is not the UI's job -- so the plural has to
-- live in the data for the rendered header to stay what it was.
--
-- This deliberately runs before the corrections: phase 1 produces both "Lab" (from
-- assignment-lab-N) and "Labs" (from labs-drop-lowest), so pluralising collides. Correction 1
-- immediately below exists to merge same-named groups, and absorbs the collision.
update public.gradebook_column_groups
set name = case name
    when 'Lab' then 'Labs'
    when 'Assignment' then 'Assignments'
    when 'Exam' then 'Exams'
    when 'Quiz' then 'Quizzes'
    when 'Skill' then 'Skills'
    else name
end
where name in ('Lab', 'Assignment', 'Exam', 'Quiz', 'Skill');

-- Correction 1: a hole in sort_order splits one family into two identically named groups.
-- In the cs4535 template, quiz-3 is absent, so quiz-1/quiz-2 and quiz-4/quiz-5 become two groups
-- both displayed as "Quiz". Merge same-named groups within a gradebook onto the earliest of them.
with canonical as (
    select
        id,
        first_value(id) over (partition by gradebook_id, name order by sort_order, id) as keep_id
    from public.gradebook_column_groups
)
update public.gradebook_columns c
set group_id = k.keep_id
from canonical k
where c.group_id = k.id
  and k.keep_id <> k.id;

delete from public.gradebook_column_groups g
where not exists (
    select 1 from public.gradebook_columns c where c.group_id = g.id
);

-- Correction 2: a two-part `assignment-<name>` slug misses the >= 3 test and is grouped under the
-- bare prefix "Assignment", far from the assignments it is not one of. In the cs4535 template this
-- is `assignment-final` ("Final Project"). Give each such column a group named after its own
-- second slug part instead.
do $$
declare
    r record;
    v_group_id bigint;
    v_label text;
begin
    for r in
        select c.id, c.slug, c.class_id, c.gradebook_id, coalesce(c.sort_order, 0) as sort_order
        from public.gradebook_columns c
        where split_part(c.slug, '-', 1) = 'assignment'
          and array_length(string_to_array(c.slug, '-'), 1) = 2
        order by c.gradebook_id, c.sort_order
    loop
        v_label := public.gradebook_column_group_pluralise(split_part(r.slug, '-', 2));

        select id into v_group_id
        from public.gradebook_column_groups
        where gradebook_id = r.gradebook_id and name = v_label
        limit 1;

        if v_group_id is null then
            insert into public.gradebook_column_groups (class_id, gradebook_id, name, sort_order)
            values (r.class_id, r.gradebook_id, v_label, r.sort_order)
            returning id into v_group_id;
        end if;

        update public.gradebook_columns set group_id = v_group_id where id = r.id;
    end loop;
end $$;

-- Correction 3: families whose slugs do not share a first word, so the heuristic cannot see them.
--   * ai-usage-log-N   -> displayed "Ai", a capitalised fragment rather than a name.
--   * meets- / approaching- / does-not-meet-expectations -> three one-column groups
--     ("Meets", "Approaching", "Does") that are levels of the skills they sit beside.
--   * labs-drop-lowest, total-labs -> two one-column groups ("Labs", "Total") that are summaries
--     of the labs, not labs.
-- Each is folded into the group it belongs to, creating that group if phase 1 did not.
do $$
declare
    r record;
    v_group_id bigint;
    m record;
begin
    for m in
        select * from (values
            ('AI Usage Logs', array['ai-usage-log-%']),
            ('Skills',        array['meets-expectations', 'approaching-expectations', 'does-not-meet-expectations']),
            ('Labs',          array['labs-drop-lowest', 'total-labs'])
        ) as t(target_name, slug_patterns)
    loop
        for r in
            select c.id, c.class_id, c.gradebook_id, coalesce(c.sort_order, 0) as sort_order
            from public.gradebook_columns c
            where exists (
                select 1 from unnest(m.slug_patterns) p where c.slug like p
            )
            order by c.gradebook_id, c.sort_order
        loop
            select id into v_group_id
            from public.gradebook_column_groups
            where gradebook_id = r.gradebook_id and name = m.target_name
            limit 1;

            if v_group_id is null then
                insert into public.gradebook_column_groups (class_id, gradebook_id, name, sort_order)
                values (r.class_id, r.gradebook_id, m.target_name, r.sort_order)
                returning id into v_group_id;
            end if;

            update public.gradebook_columns set group_id = v_group_id where id = r.id;
        end loop;
    end loop;
end $$;

-- Correction 4: columns that describe a student's standing rather than a piece of work.
-- `average.hw` (displayed "Average.hw", because a dot is not a dash), `labs-drop-lowest`,
-- `total-labs`, `curve-adjustment`, `midterm-standing`, `attendance` and `final` are each rendered
-- as a one-column group by the heuristic, so the right-hand third of the gradebook is a row of
-- unrelated single headers. They are all summaries of work rather than work, so they belong
-- together under one "Overall" header.
--
-- `assignment-final` is titled "Final Project", so correction 2's generic rule -- which named its
-- group after the slug part "final" -- lands it beside the course total. Filed under "Projects"
-- instead, which is where a project belongs and what an instructor adding a project type would
-- have chosen.
do $$
declare
    r record;
    v_group_id bigint;
    m record;
begin
    for m in
        select * from (values
            ('Overall',  array['average.hw', 'labs-drop-lowest', 'total-labs',
                               'curve-adjustment', 'midterm-standing', 'attendance', 'final']),
            ('Projects', array['assignment-final'])
        ) as t(target_name, slugs)
    loop
        for r in
            select c.id, c.class_id, c.gradebook_id, coalesce(c.sort_order, 0) as sort_order
            from public.gradebook_columns c
            where c.slug = any (m.slugs)
            order by c.gradebook_id, c.sort_order
        loop
            select id into v_group_id
            from public.gradebook_column_groups
            where gradebook_id = r.gradebook_id and name = m.target_name
            limit 1;

            if v_group_id is null then
                insert into public.gradebook_column_groups (class_id, gradebook_id, name, sort_order)
                values (r.class_id, r.gradebook_id, m.target_name, r.sort_order)
                returning id into v_group_id;
            end if;

            update public.gradebook_columns set group_id = v_group_id where id = r.id;
        end loop;
    end loop;
end $$;

-- Drop any group phase 2 emptied out.
delete from public.gradebook_column_groups g
where not exists (
    select 1 from public.gradebook_columns c where c.group_id = g.id
);

-- Renumber group sort_order to the position of each group's leftmost column, so the headers stay
-- in the same left-to-right order the columns are in.
with ordered as (
    select
        g.id,
        row_number() over (
            partition by g.gradebook_id
            order by min(coalesce(c.sort_order, 0)), g.id
        ) as new_order
    from public.gradebook_column_groups g
    join public.gradebook_columns c on c.group_id = g.id
    group by g.id, g.gradebook_id
)
update public.gradebook_column_groups g
set sort_order = o.new_order
from ordered o
where g.id = o.id;

-- ---------------------------------------------------------------------------------------------
-- Now that phase 2 has merged the duplicates phase 1 reproduced, a gradebook can no longer hold
-- two groups with the same header. Adding the constraint here rather than in the schema migration
-- is what allowed phase 1 to be a faithful reproduction.
-- ---------------------------------------------------------------------------------------------
alter table public.gradebook_column_groups
    add constraint gradebook_column_groups_gradebook_id_name_key unique (gradebook_id, name);
