/*
 * MongoDB initialisation for local and staging compose stacks.
 *
 * Runs once, on an empty data directory, via the official image's
 * docker-entrypoint-initdb.d hook. It creates the application user with the
 * least privilege that works — readWrite on one database — rather than
 * letting the application connect as root, which is what the default
 * connection string in most tutorials does.
 *
 * Production does not use this file: it runs on managed MongoDB, where the
 * user is provisioned through the provider's console and the credentials
 * arrive as environment variables.
 */

/* global db, print */

const database = process.env.MONGO_INITDB_DATABASE || 'sriko_lms';
const username = process.env.MONGO_APP_USERNAME || 'sriko_app';
const password = process.env.MONGO_APP_PASSWORD;

if (!password) {
  throw new Error(
    'MONGO_APP_PASSWORD is not set. Refusing to create an application user ' +
      'with a default password — see infrastructure/.env.example.',
  );
}

const target = db.getSiblingDB(database);

target.createUser({
  user: username,
  pwd: password,
  roles: [{ role: 'readWrite', db: database }],
});

// Creating the collections up front makes the index declarations below run on
// a real namespace, and gives the application a database that is already the
// right shape on first connect.
const collections = [
  'users',
  'courses',
  'progress',
  'subscriptions',
  'payments',
  'certificates',
  'announcements',
  'discussionforums',
  'discussionposts',
  'notifications',
  'joinussubmissions',
  'settings',
];

for (const name of collections) {
  target.createCollection(name);
}

// The uniqueness constraints the application relies on. Mongoose also declares
// these, but it declares them on connect: a race between two starting
// instances can leave a window where duplicates are accepted. Creating them
// here closes that window for a fresh database.
target.users.createIndex({ email: 1 }, { unique: true, name: 'uniq_email' });
target.payments.createIndex(
  { invoiceNumber: 1 },
  { unique: true, sparse: true, name: 'uniq_invoice' },
);
target.payments.createIndex(
  { receiptNumber: 1 },
  { unique: true, sparse: true, name: 'uniq_receipt' },
);
target.certificates.createIndex(
  { certificateNumber: 1 },
  { unique: true, name: 'uniq_certificate' },
);
target.progress.createIndex({ user: 1, course: 1 }, { unique: true, name: 'uniq_enrolment' });

print(
  `✓ initialised database "${database}" with user "${username}" and ${collections.length} collections`,
);
