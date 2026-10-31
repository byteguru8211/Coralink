'use strict';

const { requireAuth } = require('../auth');
const { HttpError, sendJson } = require('../lib/http');
const {
  isPlainObject,
  isUuidLike,
  isValidAvatarColor,
  normalizeAbout,
  normalizeName,
} = require('../lib/validate');

function toPublicUser(user, hub) {
  return {
    id: user.id,
    name: user.name,
    about: user.about,
    avatarColor: user.avatarColor,
    lastSeen: user.lastSeen,
    online: hub.isOnline(user.id),
  };
}

function toPrivateUser(user, hub) {
  return {
    ...toPublicUser(user, hub),
    phone: user.phone,
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
    const changes = { name: null, about: null, avatarColor: null };

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
    requireAuth(context);
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
      presence[id] = {
        online: target ? context.hub.isOnline(target.id) : false,
        lastSeen: target ? target.lastSeen : null,
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
