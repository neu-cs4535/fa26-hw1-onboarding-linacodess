/**
 * Grouping of gradebook columns into the headers shown above the gradebook.
 *
 * This used to be derived at render time from the column slug: split on "-", special-case
 * `assignment-<type>-<n>`, and start a new group whenever `sort_order` skipped a value. That
 * guess was wrong in ways nobody could correct -- a deleted column split its family into two
 * identically titled headers, and a two-part slug like `assignment-final` filed a final project
 * under "Assignment" -- and the same forty lines were copied into four call sites.
 *
 * Membership is now stored on `gradebook_columns.group_id`, so grouping is a read. The returned
 * shape is unchanged from the heuristic's, so the call sites that consume it did not have to move.
 */

/** Minimum a column needs to be grouped. Callers pass richer objects; the extra fields ride along. */
export type GroupableColumn = {
  id: number;
  sort_order: number | null;
  group_id: number | null;
};

export type ColumnGroupRow = {
  id: number;
  name: string;
  sort_order: number;
};

export type GroupedColumns<T extends GroupableColumn> = Record<string, { groupName: string; columns: T[] }>;

/**
 * Build the header-to-columns map.
 *
 * Groups come out in `sort_order`, and columns within a group come out in their own `sort_order`.
 * A column with no group gets an entry of its own, which is how the previous implementation also
 * rendered a column that shared its prefix with nothing: a single-column group, which the table
 * then declines to give a collapse control to.
 */
export function buildGroupedColumns<T extends GroupableColumn>(
  columns: T[],
  groups: ColumnGroupRow[]
): GroupedColumns<T> {
  const byId = new Map<number, ColumnGroupRow>(groups.map((g) => [g.id, g]));
  const sorted = [...columns].sort((a, b) => (a.sort_order ?? 0) - (b.sort_order ?? 0));

  const result: GroupedColumns<T> = {};
  const orderedKeys: { key: string; order: number }[] = [];

  for (const column of sorted) {
    const group = column.group_id == null ? undefined : byId.get(column.group_id);
    const key = group ? `group-${group.id}` : `ungrouped-${column.id}`;

    if (!result[key]) {
      result[key] = { groupName: group?.name ?? "Other", columns: [] };
      // Ordered by where the group's leftmost column sits, not by group.sort_order. The manage
      // gradebook is a horizontal table whose header row spans column ranges, so a header that
      // did not follow its columns would misalign. Reordering a group therefore means moving its
      // columns, which is what group.sort_order records the intent of.
      orderedKeys.push({ key, order: column.sort_order ?? 0 });
    }
    result[key].columns.push(column);
  }

  // Object key order is insertion order for string keys, and the table renders headers in that
  // order, so rebuild the object in the order computed above.
  orderedKeys.sort((a, b) => a.order - b.order);
  const ordered: GroupedColumns<T> = {};
  for (const { key } of orderedKeys) {
    ordered[key] = result[key];
  }
  return ordered;
}

/** The group a column belongs to, or undefined when it is ungrouped. */
export function findGroupEntryForColumn<T extends GroupableColumn>(
  grouped: GroupedColumns<T>,
  columnId: number
): [string, { groupName: string; columns: T[] }] | undefined {
  return Object.entries(grouped).find(([, group]) => group.columns.some((col) => col.id === columnId));
}
