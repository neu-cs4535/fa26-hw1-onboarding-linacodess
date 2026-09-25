# Gradebook Column Groups — Design Writeup

**Lina Boutayeb · CS 4535 HW1**

---

## Band claim

I am claiming **Distinction**.

The evidence:

- **A new table, with permission rules.**
  [`20260923210000`](../supabase/migrations/20260923210000_gradebook_column_groups.sql) creates a
  `gradebook_column_groups` table and gives every gradebook column a `group_id` field pointing at it.
  Only instructors can change groups; everyone in the class can see them.
- **Filling in every existing column.**
  [`20260924090000`](../supabase/migrations/20260924090000_backfill_gradebook_column_groups.sql) puts
  all 64 existing columns into a group. It does this in two steps: first it copies the old grouping
  exactly, then it fixes the problems listed below.
- **The gradebook reads the saved group.** Both gradebook pages now look up the saved group instead of
  guessing from the column's short name. The old guessing code appeared in four places; all four are
  gone, replaced by one function in
  [`lib/gradebookColumnGroups.ts`](../lib/gradebookColumnGroups.ts).
- **Three problems with the old grouping**, each with how I found it — below.
- **Instructors can manage groups.**
  [`20260924170000`](../supabase/migrations/20260924170000_gradebook_column_group_crud.sql) and the
  menus that use it let an instructor create a group, rename it, delete it, move columns between
  groups, and reorder them. Dragging a column to a new position no longer changes its group.

---

## Part One

### 1. What is a column group for?

A column group answers **what type of assignment a column is** — an exam, a quiz, a lab — and saves
that answer, instead of guessing it every time the page loads.

Instructors read a gradebook by type. The old code only matched that by luck, because it guessed the
type from the column's short name (its "slug"): it cut the name at the dashes and took the first
piece.

The real problem was not that the guess was sometimes wrong. It was that **nobody could fix it**. The
guess only existed while the page was drawing, and then it was thrown away. There was nothing saved,
so there was nothing to edit, so there could be no button.

A quiz filed under "Assignment" was stuck there forever:

- Renaming the column did not help, because the grouping read the slug, not the name.
- The slug could not be changed, because the system builds it automatically.
- The assignment's own name is locked once the assignment exists.

Saving the type turns a permanent verdict into a starting suggestion.

### 2. Who would I ask to check this, and what would I show them?

An instructor whose course does **not** name things the way the sample course does. My own course
cannot tell me whether my fixes work anywhere else.

I would show them three things: their gradebook before and after, a list of which column ended up in
which type, and the menus for fixing anything they disagree with.

The third one is the real test, and it is where this is weakest right now. An instructor still cannot
choose the type **when they create the assignment**. The column gets filed automatically, and they
have to go and correct it afterwards in the gradebook. That is not good enough. It should be a
dropdown on the assignment form, listing the types that already exist, with the option to type a new
one — so the column's short name never decides anything.

### 3. Which qualities did I optimise for?

**Being able to check the work, first.** I wrote the fill-in step in two parts: first copy the old
grouping exactly, bugs and all, then fix the problems one clearly labelled step at a time.

That is more work than just writing the fixed version straight away. It is worth it because anyone
reading it can tell which changes I meant to make. If I had skipped the first part, "I merged the two
quiz groups on purpose" and "I accidentally lost a group" would look exactly the same in the finished
data.

**Not losing anything, second.** If a group is deleted, its columns stay and simply have no type
anymore. All the grades are untouched. Deleting a header is a labelling action, and it must never be a
way to delete grades.

**Easier to maintain, third.** The same guessing code had been copied into four places. It is now one
function, and it hands back the same shape as before, so the roughly fifteen places that used it did
not have to change.

**I did not optimise for speed.** The old code was already fast — a few dozen rows, and it remembered
its answer. It was never slow. It was wrong.

**I also did not optimise for how it feels to use**, and that is the real cost of the choices above.
The instructor controls work, but they are not good yet. That is the next question.

### 4. Where did priorities conflict, and what did I sacrifice?

**Copying the old behaviour versus fixing it.** Pass asks for a fill-in step that reproduces what the
gradebook does today. Credit asks for the problems to be fixed. Those pull against each other.

I did both, in order: copy first, then fix in labelled steps, then add the rule that stops two groups
sharing a name. That rule goes last on purpose, because the copying step legitimately creates two
groups both called "Quiz", and the fixing step is what merges them.

**Simple permissions versus a tidier design.** I store the class on the group table even though it
could be looked up. Every permission rule in this project checks the class, so storing it means the
check reads one value instead of looking it up. The cost is that the two could end up disagreeing, and
nothing stops that. It is the weakest part of my design and the first thing I would change.

**Matching the existing permission rule versus writing a simple one.** The rule for gradebook columns
was tightened at some point so students cannot see instructor-only columns until they are released. If
I had copied the older, simpler rule, a student could have seen a header for a group whose columns are
all hidden from them — undoing that protection. So I matched the stricter version: a student sees a
group only if it holds at least one column they are allowed to see. I checked this on the student page,
where "Overall" shows 6 of its 7 columns, because one is instructor-only.

**Saving a name changes what the app is allowed to do with it.** Both pages used to add an "s" to the
group name when displaying it. That was fine when the name was made by the system from a word like
`lab`. Once the name is something a person typed, changing it is wrong — "Overall" was showing up as
"Overalls". I removed that and saved the plural in the data instead.

**Getting the data right versus making it pleasant to use.** This is the sacrifice I actually made. I
spent the time on the table, the fill-in step, and proving that neither loses data. What was left went
on the instructor controls. They work, but they are not the design I would defend:

- **The type is chosen in the wrong place.** It should be picked when the assignment is created, from
  a dropdown of existing types with the option to add a new one, and be editable later. Right now it
  is filed automatically and has to be corrected afterwards.
- **"Move to" does not scale.** It shows one menu line per group — "Move to Labs", "Move to Exams",
  and so on. That is already hard to read with ten groups and impossible with a hundred. It should be
  a single "Move to…" that opens a list you can search.
- **Only one column can be moved at a time.** The database side already accepts a list of columns, so
  moving every quiz into "Exams" in one action is possible. The menu just never sends more than one.
  This is a gap in the interface, not in the design.
- **Renaming a group is not obvious**, and right now it clears the headers instead of updating them.
  Renaming a header should be as simple as clicking on it.

I would rather hand in a fill-in step I can prove is correct with a rough interface, than a polished
interface over one I cannot. But the rough interface is a real cost, not a detail — the whole argument
for saving the type is that someone can correct it, and correcting it is currently harder than it
should be.

---

## Three problems with the old grouping

### Problem 1 — a missing position splits one type into two identical headers

- **What I expected:** the four quizzes under one "Quizzes" header.
- **What happened:** two headers, both saying "2 Quizzes…". Quiz 1 and 2 under the first, Quiz 4 and 5
  under the second, with nothing to tell them apart.
- **How I found it:** I noticed the repeated header on the gradebook, then looked at the rows in
  Supabase Studio. The four quizzes sit at positions 11, 12, 14, 15. Position 13 is empty, because
  `quiz-3` does not exist.
- **Why it happens:** the old code only kept a group going while the positions counted up one at a
  time. Going from 12 to 14 breaks that, so it started a new group — even though the name had not
  changed.
- **How I fixed it:** the fill-in step merges groups that share a name.

### Problem 2 — an assignment's column cannot be put in the right type

- **What I expected:** an assignment called "quiz 10" to be grouped with the quizzes.
- **What happened:** it got its own header saying "Assignment", at the far right of the gradebook.
- **How I found it:** I created an assignment with the short name `quiz10` on purpose, to see where a
  new column would land. Then I looked at the row it produced. Its slug had come out as
  `assignment-quiz10` — the `assignment-` part was added automatically, not by me.
- **Why it happens:** two things combine. The system always puts `assignment-` in front of the name I
  choose. And the rule that recognises a type only works when the name has **three or more** pieces
  separated by dashes. `assignment-quiz10` has two, so it falls back to just `assignment`.
- **How I fixed it:** the fill-in step names the group after the second piece of the name instead, and
  new columns are filed the same way as they are created.

### Problem 3 — one dash decides whether a column is grouped correctly

- **What I expected:** two assignments created the same way to be grouped the same way.
- **What happened:** the name `quiz10` produces the header "Assignment". The name `quiz-11` produces
  "Quiz". One keystroke apart.
- **How I found it:** after Problem 2, I worked out the "three or more pieces" rule and listed every
  column in the sample course by how many dashes it has. That predicted that adding one dash would
  change the answer. I tested it: I created an assignment called `quiz-6`, the system produced
  `assignment-quiz-6`, and it joined the Quizzes group — where `quiz10` had not.
- **Why it happens:** the extra dash pushes the name from two pieces to three, which is what the rule
  is counting.
- **How I fixed it:** both shapes are now handled the same way, in the fill-in step and for new
  columns.

### Also noticed

- **`average.hw`** uses a dot instead of a dash, so the name never gets split and the header reads
  "Average.hw".
- **A group can only say one thing about a column.** `skill-1` through `skill-12` are skills, while
  "Meets Expectations", "Approaching Expectations" and "Does Not Meet Expectations" are _levels_ those
  skills land at. Skill and level are two separate things, and a column can only be in one group. The
  same is true of the AI Usage Logs, which belong both to their own family and to a specific
  assignment. This is a limit of the design itself, not a bug — see Part Two.

---

## Testing

### Courses and columns tested

- The `cs4535` sample course: 40 gradebook columns, covering every case above.
- All three gradebooks in the database, not only the sample course — 64 columns in total, none left
  without a group.
- Both the instructor gradebook and the student gradebook, signed in as each, to check the permission
  rules.
- The instructor controls, run in a way that was undone afterwards: creating a group, renaming it,
  moving the attendance column into it, then deleting it. After the delete, the attendance column was
  still there with all 48 of its scores.

### Commands run

```bash
npx supabase db reset                      # rebuild the database from scratch
npm run client-local                       # update the type definitions after a schema change
npm run seed -- --template cs4535
npx tsc --noEmit -p tsconfig.json
npm run lint
```

Rebuilding from scratch is what showed that the fill-in step alone is not enough. It only groups the
columns that exist at the moment it runs — and on an empty database, that is none. The sample course
is created afterwards, so its 40 columns had no group at all. Since the grading workflow does exactly
this (rebuild, then create the course), the gradebook would have shown no headers at all. Fixed by
[`20260924140000`](../supabase/migrations/20260924140000_assign_gradebook_column_group_on_insert.sql),
which files each new column as it is created.

### Rollback strategy

In reverse order: remove the five instructor functions, remove the rule that files new columns and its
two helpers, remove the unique-name rule, then remove the `group_id` field and finally the
`gradebook_column_groups` table.

Removing `group_id` loses which group each column was in. **No grades are affected** — scores are
stored separately and this feature never touches them. The gradebook would go back to the old
guessing, so undoing the database changes also means undoing the code changes that deleted it.

The uncomfortable case is undoing this **after** instructors have set up groups by hand. That work
cannot be recovered, because the old guessing has no way to store it. A safer version would remove the
rules but leave `group_id` in place — unused, but not thrown away.

---

## Part Two — the multi-attempt case

CS 2100's columns are attempts at topics: `recursion-try1`, `pointers-attempt-a`. The topic is the
real idea, but the names share no common first word, so no rule based on the name can find it.

**What the current design cannot say.** A column here has **two labels at once** — a topic and an
attempt number — and it can only be in one group. This is the same limit I hit in my own course, where
a skill column has both a skill and a level. Adding a second field would not solve it either; the next
course will have three labels, not two.

**What the display should do instead.** Groups are probably the wrong shape. Topic and attempt form a
grid: topics down the side, attempts across the top, and one column holding the grade that counts —
best attempt or latest attempt, and only the instructor can say which. A flat row of headers cannot
show that a student has three tries at recursion and one at pointers.

**What it would cost.** A separate table of labels, one row per column per label, plus a setting for
which label is the main one. A fill-in step that cannot work the labels out from the names and so
needs the instructor to supply them. At 40 topics, 3 attempts and 300 students that is 36,000 cells
per page, which is too many to work out in the browser the way the gradebook does today — it would
need to be summarised on the server. And real instructor effort, because the labels cannot be guessed.

**What I still do not know.** Whether the grade is the best attempt or the latest one. Whether there is
a limit on attempts. Whether a topic can be passed without every attempt being graded. Those are
questions for the CS 2100 instructor, and the answers change the database design, not just the
display.
