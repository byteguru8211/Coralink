'use strict';

const { requireAuth } = require('../auth');
const { HttpError, sendJson } = require('../lib/http');
const {
  isPlainObject,
  isUuidLike,
  isValidAvatarColor,
  normalizeAbout,
  normalizeAvatar,
  normalizeName,
} = require('../lib/validate');

function toPublicUser(user, hub) {
  return {
    id: user.id,
    username: user.username ?? null,
    name: user.name,
    about: user.about,
    avatarColor: user.avatarColor,
    avatar: user.avatar || '',
    lastSeen: user.lastSeen,
    online: hub.isOnline(user.id),
  };
}

function toPrivateUser(user, hub) {
  return {
    ...toPublicUser(user, hub),
    phone: user.phone ?? null,
    createdAt: user.createdAt,
  };
}

function requireBody(context) {
  if (!isPlainObject(context.body)) {
    throw new HttpError(400, 'invalid_request', 'A JSON object is required');
  }
  return context.body;
}

function registerUserRoutes(router) {
  router.add('GET', '/api/v1/me', async (context) => {
    const user = requireAuth(context);
    sendJson(context.res, 200, {
      user: toPrivateUser(user, context.hub),
    });
  });

  router.add('PATCH', '/api/v1/me', async (context) => {
    const user = requireAuth(context);
    const body = requireBody(context);
    const changes = {
      name: null,
      about: null,
      avatarColor: null,
      avatar: null,
      presenceVisibility: null,
    };

    if (body.name !== undefined) {
      const name = normalizeName(body.name);
      if (name === null) {
        throw new HttpError(
          400,
          'invalid_name',
          'Name must be between 1 and 64 characters',
        );
      }
      changes.name = name;
    }

    if (body.about !== undefined) {
      const about = normalizeAbout(body.about);
      if (about === null) {
        throw new HttpError(
          400,
          'invalid_about',
          'About must be at most 280 characters',
        );
      }
      changes.about = about;
    }

    if (body.avatarColor !== undefined) {
      if (!isValidAvatarColor(body.avatarColor)) {
        throw new HttpError(
          400,
          'invalid_avatar_color',
          'avatarColor must match #RRGGBB',
        );
      }
      changes.avatarColor = body.avatarColor;
    }

    if (body.avatar !== undefined) {
      const avatar = normalizeAvatar(body.avatar);
      if (avatar === null) {
        throw new HttpError(
          400,
          'invalid_avatar',
          'avatar must be a base64 image data URL (png/jpeg/webp) under 500 KB',
        );
      }
      changes.avatar = avatar;
    }

    if (body.presenceVisibility !== undefined) {
      if (!['everyone', 'contacts', 'nobody'].includes(body.presenceVisibility)) {
        throw new HttpError(
          400,
          'invalid_presence_visibility',
          'presenceVisibility must be everyone, contacts or nobody',
        );
      }
      changes.presenceVisibility = body.presenceVisibility;
    }

    const updated = context.db.updateUserProfile(user.id, changes);
    sendJson(context.res, 200, {
      user: toPrivateUser(updated, context.hub),
    });
  });

  router.add('DELETE', '/api/v1/me', async (context) => {
    const user = requireAuth(context);
    context.db.deleteUser(user.id);
    if (typeof context.hub.disconnectUser === 'function') {
      context.hub.disconnectUser(user.id);
    }
    sendJson(context.res, 200, { ok: true });
  });

  router.add('GET', '/api/v1/users/search', async (context) => {
    const user = requireAuth(context);
    const rawQuery = context.url.searchParams.get('q');
    if (typeof rawQuery !== 'string') {
      throw new HttpError(400, 'invalid_query', 'Search query is required');
    }
    const query = rawQuery.trim();
    if (query.length === 0 || query.length > 64) {
      throw new HttpError(
        400,
        'invalid_query',
        'Search query must be between 1 and 64 characters',
      );
    }
    const users = context.db.searchUsers(query, user.id, 20);
    sendJson(context.res, 200, {
      users: users.map((entry) => toPublicUser(entry, context.hub)),
    });
  });

  router.add('GET', '/api/v1/users/:id', async (context) => {
    requireAuth(context);
    const target = context.db.getUserById(context.params.id);
    if (!target) {
      throw new HttpError(404, 'user_not_found', 'User not found');
    }
    sendJson(context.res, 200, {
      user: toPublicUser(target, context.hub),
    });
  });

  router.add('GET', '/api/v1/contacts', async (context) => {
    const user = requireAuth(context);
    const contacts = context.db.getContacts(user.id);
    sendJson(context.res, 200, {
      contacts: contacts.map((entry) => toPublicUser(entry, context.hub)),
    });
  });

  router.add('POST', '/api/v1/contacts', async (context) => {
    const user = requireAuth(context);
    const body = requireBody(context);
    if (!isUuidLike(body.userId)) {
      throw new HttpError(400, 'invalid_user_id', 'A valid userId is required');
    }
    if (body.userId === user.id) {
      throw new HttpError(400, 'cannot_add_self', 'Cannot add yourself');
    }
    const target = context.db.getUserById(body.userId);
    if (!target) {
      throw new HttpError(404, 'user_not_found', 'User not found');
    }
    context.db.addContact(user.id, target.id);
    sendJson(context.res, 201, {
      contact: toPublicUser(target, context.hub),
    });
  });

  router.add('DELETE', '/api/v1/contacts/:userId', async (context) => {
    const user = requireAuth(context);
    context.db.removeContact(user.id, context.params.userId);
    sendJson(context.res, 200, { ok: true });
  });

  router.add('GET', '/api/v1/presence', async (context) => {
    const requester = requireAuth(context);
    const rawIds = context.url.searchParams.get('ids');
    if (typeof rawIds !== 'string' || rawIds.trim() === '') {
      throw new HttpError(400, 'invalid_ids', 'ids query parameter is required');
    }
    const ids = Array.from(
      new Set(
        rawIds
          .split(',')
          .map((id) => id.trim())
          .filter(Boolean),
      ),
    );
    if (ids.length === 0 || ids.length > 100) {
      throw new HttpError(
        400,
        'invalid_ids',
        'Provide between 1 and 100 user ids',
      );
    }
    const presence = {};
    for (const id of ids) {
      if (id.length > 128) {
        throw new HttpError(400, 'invalid_ids', 'Invalid user id');
      }
      const target = context.db.getUserById(id);
      let visible = Boolean(target);
      if (target) {
        const visibility = target.presenceVisibility || 'contacts';
        if (visibility === 'nobody' && target.id !== requester.id) {
          visible = false;
        } else if (visibility === 'contacts' && target.id !== requester.id) {
          visible =
            context.db.isContact(target.id, requester.id) ||
            context.db.isContact(requester.id, target.id);
        }
      }
      presence[id] = {
        online: visible ? context.hub.isOnline(target.id) : false,
        lastSeen: visible ? target.lastSeen : null,
      };
    }
    sendJson(context.res, 200, { presence });
  });
}

module.exports = {
  registerUserRoutes,
  toPrivateUser,
  toPublicUser,
};
