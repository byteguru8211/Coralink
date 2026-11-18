'use strict';

const { randomUUID } = require('node:crypto');
const { requireAuth } = require('../auth');
const { HttpError, sendJson } = require('../lib/http');
const { isPlainObject } = require('../lib/validate');

const MAX_TITLE = 64;
const MAX_MEMBERS = 256;

function requireBody(context) {
  if (!isPlainObject(context.body)) {
    throw new HttpError(400, 'invalid_request', 'A JSON object is required');
  }
  return context.body;
}

function normalizeTitle(input) {
  if (typeof input !== 'string') return null;
  const value = input.trim();
  if (value.length < 1 || value.length > MAX_TITLE) return null;
  return value;
}

function registerGroupRoutes(router) {
  // Create a group with an initial member set.
  router.add('POST', '/api/v1/groups', async (context) => {
    const user = requireAuth(context);
    const body = requireBody(context);
    const title = normalizeTitle(body.title);
    if (title === null) {
      throw new HttpError(
        400,
        'invalid_title',
        `Title must be between 1 and ${MAX_TITLE} characters`,
      );
    }
    const avatar = typeof body.avatar === 'string' ? body.avatar.slice(0, 500_000) : '';
    const requested = Array.isArray(body.members) ? body.members : [];
    if (requested.length > MAX_MEMBERS) {
      throw new HttpError(400, 'too_many_members', 'Too many initial members');
    }
    const memberIds = new Set([user.id]);
    for (const id of requested) {
      if (typeof id === 'string' && context.db.getUserById(id)) memberIds.add(id);
    }
    const group = context.db.createGroup({
      id: randomUUID(),
      title,
      avatar,
      createdBy: user.id,
      memberIds: Array.from(memberIds),
      createdAt: Date.now(),
    });
    sendJson(context.res, 201, {
      group,
      members: context.db.listGroupMembers(group.id),
    });
  });

  // List the caller's groups.
  router.add('GET', '/api/v1/groups', async (context) => {
    const user = requireAuth(context);
    sendJson(context.res, 200, { groups: context.db.listGroupsForUser(user.id) });
  });

  // Pending group messages for the caller (offline queue).
  router.add('GET', '/api/v1/groups/queued', async (context) => {
    const user = requireAuth(context);
    const messages = context.db.getPendingGroupMessages(user.id);
    sendJson(context.res, 200, {
      messages: messages.map((m) => ({
        id: m.id,
        groupId: m.groupId,
        senderId: m.senderId,
        ciphertext: m.ciphertext,
        kind: m.kind,
        meta: m.meta,
        createdAt: m.createdAt,
      })),
    });
  });

  // Acknowledge (mark delivered) group messages.
  router.add('POST', '/api/v1/groups/ack', async (context) => {
    const user = requireAuth(context);
    const body = requireBody(context);
    const ids = Array.isArray(body.ids) ? body.ids.filter((x) => typeof x === 'string') : [];
    const result = context.db.ackGroupMessages(user.id, ids);
    sendJson(context.res, 200, { ok: true, acked: result.acked, bySender: result.bySender });
  });

  // Group detail + members (membership required).
  router.add('GET', '/api/v1/groups/:id', async (context) => {
    const user = requireAuth(context);
    const group = context.db.getGroup(context.params.id);
    if (!group) throw new HttpError(404, 'group_not_found', 'Group not found');
    if (!context.db.isGroupMember(group.id, user.id)) {
      throw new HttpError(403, 'not_a_member', 'You are not a member of this group');
    }
    sendJson(context.res, 200, {
      group,
      members: context.db.listGroupMembers(group.id),
    });
  });

  // Add a member (any current member may invite).
  router.add('POST', '/api/v1/groups/:id/members', async (context) => {
    const user = requireAuth(context);
    const group = context.db.getGroup(context.params.id);
    if (!group) throw new HttpError(404, 'group_not_found', 'Group not found');
    if (!context.db.isGroupMember(group.id, user.id)) {
      throw new HttpError(403, 'not_a_member', 'Only members can invite');
    }
    const body = requireBody(context);
    const targetId = typeof body.userId === 'string' ? body.userId : '';
    const target = targetId ? context.db.getUserById(targetId) : null;
    if (!target) throw new HttpError(404, 'user_not_found', 'User not found');
    context.db.addGroupMember(group.id, target.id, 'member');
    sendJson(context.res, 201, {
      members: context.db.listGroupMembers(group.id),
    });
  });

  // Leave (self) or remove (owner/admin).
  router.add(
    'DELETE',
    '/api/v1/groups/:id/members/:userId',
    async (context) => {
      const user = requireAuth(context);
      const group = context.db.getGroup(context.params.id);
      if (!group) throw new HttpError(404, 'group_not_found', 'Group not found');
      const targetId = context.params.userId;
      if (targetId !== user.id) {
        const members = context.db.listGroupMembers(group.id);
        const me = members.find((m) => m.id === user.id);
        if (!me || (me.role !== 'owner' && me.role !== 'admin')) {
          throw new HttpError(403, 'not_allowed', 'Only an admin can remove members');
        }
      }
      context.db.removeGroupMember(group.id, targetId);
      sendJson(context.res, 200, { ok: true });
    },
  );
}

module.exports = { registerGroupRoutes };
