"use client";

/**
 * Instructor controls for gradebook column groups.
 *
 * Grouping used to be inferred from the column slug at render time, so there was nothing to edit:
 * a mis-grouped column could only be fixed by renaming the slug, which is generated for
 * assignment-backed columns and locked after creation. Membership is stored now, so these controls
 * are what make the insert trigger's slug-derived default a suggestion rather than a verdict.
 *
 * Every mutation goes through an RPC in 20260924170000_gradebook_column_group_crud.sql. Those are
 * SECURITY INVOKER, so the "instructors CRUD" RLS policy is what authorizes the caller -- there is
 * no permission check duplicated here that could drift from the one in the database.
 */

import { Icon, Input, Portal } from "@chakra-ui/react";
import { MenuContent, MenuItem, MenuRoot, MenuSeparator, MenuTrigger } from "@/components/ui/menu";
import { toaster } from "@/components/ui/toaster";
import { Button } from "@/components/ui/button";
import {
  DialogBody,
  DialogCloseTrigger,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogRoot,
  DialogTitle
} from "@/components/ui/dialog";
import { useGradebookColumnGroups, useGradebookController } from "@/hooks/useGradebook";
import { createClient } from "@/utils/supabase/client";
import { useCallback, useState } from "react";
import { LuFolderPlus, LuPencil, LuTrash2, LuFolderInput, LuFolderMinus } from "react-icons/lu";

/** Prompt for a group name. Used by both "New group" and "Rename". */
function GroupNameDialog({
  title,
  initialValue,
  confirmLabel,
  onConfirm,
  onClose
}: {
  title: string;
  initialValue: string;
  confirmLabel: string;
  onConfirm: (name: string) => Promise<void>;
  onClose: () => void;
}) {
  const [value, setValue] = useState(initialValue);
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  const submit = useCallback(async () => {
    if (!value.trim()) {
      setError("Enter a group name first");
      return;
    }
    setSaving(true);
    try {
      await onConfirm(value.trim());
      onClose();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not save the group");
    } finally {
      setSaving(false);
    }
  }, [value, onConfirm, onClose]);

  return (
    <DialogRoot open onOpenChange={(d) => !d.open && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{title}</DialogTitle>
        </DialogHeader>
        <DialogBody>
          <Input
            autoFocus
            value={value}
            placeholder="e.g. Projects"
            onChange={(e) => {
              setValue(e.target.value);
              if (error) setError(null);
            }}
            onKeyDown={(e) => {
              if (e.key === "Enter") submit();
            }}
          />
          {error && (
            <p style={{ color: "var(--chakra-colors-fg-error)", fontSize: "13px", marginTop: "6px" }}>{error}</p>
          )}
        </DialogBody>
        <DialogFooter>
          <Button variant="ghost" onClick={onClose}>
            Cancel
          </Button>
          <Button onClick={submit} loading={saving}>
            {confirmLabel}
          </Button>
        </DialogFooter>
        <DialogCloseTrigger />
      </DialogContent>
    </DialogRoot>
  );
}

/** Menu on a group header: rename it, delete it, or start a new one. */
export function GroupHeaderMenu({ groupId, groupName }: { groupId: number | null; groupName: string }) {
  const controller = useGradebookController();
  const supabase = createClient();
  const [dialog, setDialog] = useState<"rename" | "create" | null>(null);

  const rename = useCallback(
    async (name: string) => {
      if (groupId == null) return;
      const { error } = await supabase.rpc("rename_gradebook_column_group", {
        p_group_id: groupId,
        p_name: name
      });
      if (error) throw new Error(error.message);
      toaster.create({ title: `Renamed to "${name}"`, type: "success" });
    },
    [groupId, supabase]
  );

  const create = useCallback(
    async (name: string) => {
      const { error } = await supabase.rpc("create_gradebook_column_group", {
        p_gradebook_id: controller.gradebook_id,
        p_name: name
      });
      if (error) throw new Error(error.message);
      toaster.create({ title: `Created "${name}"`, type: "success" });
    },
    [controller.gradebook_id, supabase]
  );

  const remove = useCallback(async () => {
    if (groupId == null) return;
    const { error } = await supabase.rpc("delete_gradebook_column_group", { p_group_id: groupId });
    if (error) {
      toaster.error({ title: "Could not delete the group", description: error.message });
      return;
    }
    toaster.create({
      title: `Deleted "${groupName}"`,
      description: "Its columns are now ungrouped. No grades were changed.",
      type: "success"
    });
  }, [groupId, groupName, supabase]);

  return (
    <>
      {dialog === "rename" && (
        <GroupNameDialog
          title="Rename group"
          initialValue={groupName}
          confirmLabel="Rename"
          onConfirm={rename}
          onClose={() => setDialog(null)}
        />
      )}
      {dialog === "create" && (
        <GroupNameDialog
          title="New group"
          initialValue=""
          confirmLabel="Create"
          onConfirm={create}
          onClose={() => setDialog(null)}
        />
      )}
      <MenuRoot>
        <MenuTrigger asChild>
          <button
            aria-label={`Options for the ${groupName} group`}
            onClick={(e) => e.stopPropagation()}
            style={{ padding: "0 4px", lineHeight: 1, cursor: "pointer" }}
          >
            ⋯
          </button>
        </MenuTrigger>
        <Portal>
          <MenuContent minW="180px" onClick={(e) => e.stopPropagation()}>
            <MenuItem value="rename" disabled={groupId == null} onClick={() => setDialog("rename")}>
              <Icon as={LuPencil} boxSize={3} mr={2} />
              Rename group
            </MenuItem>
            <MenuItem value="create" onClick={() => setDialog("create")}>
              <Icon as={LuFolderPlus} boxSize={3} mr={2} />
              New group
            </MenuItem>
            <MenuSeparator />
            <MenuItem value="delete" color="fg.error" disabled={groupId == null} onClick={remove}>
              <Icon as={LuTrash2} boxSize={3} mr={2} />
              Delete group
            </MenuItem>
          </MenuContent>
        </Portal>
      </MenuRoot>
    </>
  );
}

/**
 * Menu entries for moving one column into another group. Rendered inside the existing column
 * menu rather than as a menu of its own, because "which group is this in" belongs with the rest
 * of the column's settings.
 */
export function MoveColumnToGroupMenuItems({
  columnId,
  currentGroupId
}: {
  columnId: number;
  currentGroupId: number | null;
}) {
  const groups = useGradebookColumnGroups();
  const supabase = createClient();
  const [creating, setCreating] = useState(false);

  const moveTo = useCallback(
    async (groupId: number | null, label: string) => {
      const { error } = await supabase.rpc("set_gradebook_column_group", {
        p_column_ids: [columnId],
        // Omitted rather than null: the RPC defaults p_group_id to null, which is "no group".
        p_group_id: groupId ?? undefined
      });
      if (error) {
        toaster.error({ title: "Could not move the column", description: error.message });
        return;
      }
      toaster.create({ title: label, type: "success" });
    },
    [columnId, supabase]
  );

  const createAndMove = useCallback(
    async (name: string) => {
      const { data, error } = await supabase
        .rpc("create_gradebook_column_group", { p_gradebook_id: groups[0]?.gradebook_id, p_name: name })
        .single();
      if (error) throw new Error(error.message);
      const created = data as { id: number } | null;
      if (created) await moveTo(created.id, `Moved to "${name}"`);
    },
    [groups, moveTo, supabase]
  );

  const sorted = [...groups].sort((a, b) => a.sort_order - b.sort_order);

  return (
    <>
      {creating && (
        <GroupNameDialog
          title="New group for this column"
          initialValue=""
          confirmLabel="Create and move"
          onConfirm={createAndMove}
          onClose={() => setCreating(false)}
        />
      )}
      <MenuSeparator />
      {sorted
        .filter((g) => g.id !== currentGroupId)
        .map((g) => (
          <MenuItem key={g.id} value={`group-${g.id}`} onClick={() => moveTo(g.id, `Moved to "${g.name}"`)}>
            <Icon as={LuFolderInput} boxSize={3} mr={2} />
            Move to {g.name}
          </MenuItem>
        ))}
      <MenuItem value="new-group" onClick={() => setCreating(true)}>
        <Icon as={LuFolderPlus} boxSize={3} mr={2} />
        Move to a new group…
      </MenuItem>
      {currentGroupId != null && (
        <MenuItem value="ungroup" onClick={() => moveTo(null, "Removed from its group")}>
          <Icon as={LuFolderMinus} boxSize={3} mr={2} />
          Remove from group
        </MenuItem>
      )}
    </>
  );
}
