import 'docs_content.dart';

/// The manual, in reading order.
///
/// The rail groups these by [DocsChapter.group] and the footer walks them in
/// this order, so a chapter added here appears in both without any other edit.
const List<DocsChapter> docsChapters = <DocsChapter>[
  _welcome,
  _tour,
  _firstConnection,
  _connections,
  _sqlSources,
  _documentSources,
  _objectStorage,
  _httpSources,
  _vectorSources,
  _browse,
  _query,
  _schema,
  _files,
  _vectors,
  _export,
  _settings,
  _shortcuts,
  _security,
  _troubleshooting,
];

/// The chapter to open the page on.
DocsChapter get docsHome => docsChapters.first;

/// The chapter with this id, or the first one.
DocsChapter docsChapterById(String id) => docsChapters.firstWhere(
  (chapter) => chapter.id == id,
  orElse: () => docsChapters.first,
);

// ---------------------------------------------------------------------------
// Getting started
// ---------------------------------------------------------------------------

const _welcome = DocsChapter(
  id: 'welcome',
  group: DocsGroup.start,
  title: 'What Dextr is',
  summary:
      'One window for every data source you use — and four words that explain '
      'the whole interface.',
  sections: <DocsSection>[
    DocsSection(
      id: 'one-window',
      title: 'One window instead of five tools',
      blocks: <DocsBlock>[
        DocsProse(
          'A normal afternoon: psql for one database, a Mongo shell for '
          'another, a desktop client for MySQL, a browser tab for an S3 '
          'bucket, and curl for a REST endpoint. Five tools, five mental '
          'models, five chances to paste a production password somewhere it '
          'will stay.',
        ),
        DocsProse(
          'Dextr puts all of them in one tabbed workspace. Every source is '
          'browsed the same way, queried the same way and exported the same '
          'way, and every credential you type goes into the operating '
          'system keychain instead of your shell history.',
        ),
        DocsBullets(<String>[
          'SQL databases — SQLite, PostgreSQL, MySQL.',
          'Document stores — MongoDB, Firestore.',
          'Object storage — S3 and anything that speaks its API, including MinIO.',
          'HTTP endpoints — REST and GraphQL, as saved calls you can rerun.',
          'Vector databases — Qdrant, Chroma, Pinecone, Weaviate, plotted as a space you can turn.',
        ]),
        DocsNote(
          title: 'Desktop only, by design',
          description:
              'Dextr talks to databases over raw TCP sockets and opens SQLite '
              'files through native code. Neither exists in a browser, so '
              'there is no web build, and phones are not a target.',
        ),
      ],
    ),
    DocsSection(
      id: 'four-words',
      title: 'Four words that describe the whole app',
      blocks: <DocsBlock>[
        DocsProse(
          'Learn these four and every screen reads itself. They are the same '
          'four whether you are looking at a Postgres schema or a bucket of '
          'JPEGs.',
        ),
        DocsFacts(<DocsFact>[
          DocsFact(
            'Connection',
            'One saved place to reach: a database server, a file, a bucket, an '
                'endpoint. It has a name you choose and a credential kept in the '
                'keychain.',
          ),
          DocsFact(
            'Object',
            'One thing inside a connection — a table, a view, a collection, a '
                'bucket, a saved HTTP call. The rail lists them under the open '
                'connection.',
          ),
          DocsFact(
            'Tab',
            'One object you are working on. Open as many as you like; they '
                'stay open while you move between connections.',
          ),
          DocsFact(
            'View',
            'How you are looking at that object: Browse, Query, Schema or '
                'Vectors. Only the views the backend actually supports are '
                'available, so a bucket never offers you SQL.',
          ),
        ]),
      ],
    ),
    DocsSection(
      id: 'where-it-runs',
      title: 'Where it runs, and how to install it',
      blocks: <DocsBlock>[
        DocsTable(
          label: 'Supported platforms and release artifacts',
          headers: <String>['Platform', 'Architectures', 'Installed to'],
          rows: <List<String>>[
            <String>[
              'macOS',
              'universal, arm64, x64',
              '/Applications/Dextr.app',
            ],
            <String>[
              'Windows',
              'x64',
              r'%LOCALAPPDATA%\Programs\dextr, plus a Start Menu shortcut',
            ],
            <String>[
              'Linux',
              'x64',
              '/opt/dextr, with a dextr command and a desktop entry',
            ],
          ],
        ),
        DocsProse(
          'The install scripts fetch the artifact for your platform from the '
          'latest GitHub release, check it against the published SHA256SUMS, '
          'and refuse to install anything whose digest does not match.',
        ),
        DocsCode(
          'curl -fsSL https://raw.githubusercontent.com/JayashBhandary/dextr/main/install.sh | sh',
          language: 'bash',
        ),
        DocsCode(
          'irm https://raw.githubusercontent.com/JayashBhandary/dextr/main/install.ps1 | iex',
          language: 'powershell',
        ),
        DocsNote(
          kind: DocsNoteKind.warning,
          title: 'The first launch on macOS is refused once',
          description:
              'macOS builds are unsigned, so Gatekeeper stops the first open. '
              'Right-click Dextr.app and choose Open, or use Open Anyway in '
              'System Settings › Privacy & Security. Once only, then it '
              'launches normally.',
        ),
      ],
    ),
  ],
);

const _tour = DocsChapter(
  id: 'tour',
  group: DocsGroup.start,
  title: 'The workspace, part by part',
  summary: 'What each region of the window is for, and what it will tell you.',
  sections: <DocsSection>[
    DocsSection(
      id: 'rail',
      title: 'The connections rail',
      blocks: <DocsBlock>[
        DocsProse(
          'Down the left edge: every connection you have saved, with the '
          'objects of the open one indented underneath. One tree rather than '
          'two lists, because a table belongs to a connection and splitting '
          'them makes you hold that relationship in your head.',
        ),
        DocsBullets(<String>[
          'Click a connection to open it. Dextr connects in the background and the status line at the bottom says how it went.',
          'Click a table, collection or bucket to open it in a tab.',
          'Every row carries an actions menu — Edit connection, Disconnect, Delete connection — so you never have to open a connection to fix it.',
          'New connection and Docs are pinned at the bottom; Settings is the gear beside the Connections heading. Collapsed, all three become icons in the footer.',
        ]),
        DocsKeys(<DocsKey>[
          DocsKey(
            <String>['⌘', 'B'],
            'Collapse the rail to icons, and expand it again',
            spoken: 'Command B',
          ),
        ]),
        DocsProse(
          'Collapsed, the rail keeps the connections and drops the objects '
          'inside them: twenty identical table glyphs in a 64-pixel column '
          'say less than the connection they belong to. Expand it again to '
          'get back to the objects.',
        ),
      ],
    ),
    DocsSection(
      id: 'tabs-and-views',
      title: 'Tabs and views',
      blocks: <DocsBlock>[
        DocsProse(
          'The strip across the top of the workspace is the objects you have '
          'open. Under it, a segmented control switches how the open object '
          'is shown.',
        ),
        DocsFacts(<DocsFact>[
          DocsFact(
            'Browse',
            'A page of rows, or the folders of an object store.',
          ),
          DocsFact(
            'Query',
            'A raw query against the connection, with its results underneath.',
          ),
          DocsFact(
            'Schema',
            'The columns of this object: names, types, primary keys.',
          ),
          DocsFact(
            'Vectors',
            'A vector collection projected into a plot you can turn.',
          ),
        ]),
        DocsProse(
          'A view the backend cannot do is dimmed rather than hidden. A '
          'control that disappears moves everything beside it, and you learn '
          'more from a greyed-out Query than from wondering where it went.',
        ),
        DocsProse(
          'Tabs carry no close button of their own — one tab would then hold '
          'two things to click. Closing lives on the keyboard and in the menu '
          'at the end of the strip, next to the button that opens a fresh '
          'query tab.',
        ),
      ],
    ),
    DocsSection(
      id: 'status-line',
      title: 'The status line, and narrow windows',
      blocks: <DocsBlock>[
        DocsProse(
          'Along the bottom: a dot, the connection state in words, the kind of '
          'source, and how many objects you have open. The words are always '
          'there — the colour of the dot is never the only signal.',
        ),
        DocsTable(
          label: 'What the connection states mean',
          headers: <String>['State', 'Means'],
          rows: <List<String>>[
            <String>['Idle', 'Nothing is open yet.'],
            <String>['Connecting…', 'The connection is being opened.'],
            <String>['Connected', 'Ready. Browse, query and export are live.'],
            <String>[
              'Not connected',
              'The last attempt failed. The pane shows the error the backend '
                  'returned.',
            ],
          ],
        ),
        DocsProse(
          'Below about 820 pixels wide the rail moves into a drawer you open '
          'when you want it, so a narrow window spends its width on the data '
          'rather than on the navigation.',
        ),
      ],
    ),
  ],
);

const _firstConnection = DocsChapter(
  id: 'first-connection',
  group: DocsGroup.start,
  title: 'Your first connection',
  summary: 'From an empty rail to a table of rows, in about a minute.',
  sections: <DocsSection>[
    DocsSection(
      id: 'walkthrough',
      title: 'Six steps',
      blocks: <DocsBlock>[
        DocsSteps(<String>[
          'Press New connection at the bottom of the rail.',
          'Pick what you are connecting to. Each card says in one line what that source is; the ones this build cannot open are disabled.',
          'Name the connection. This is what you will see in the rail, so name it after the environment — "billing staging" beats "postgres".',
          'Fill in the fields for that source. Only the fields that source actually needs are shown.',
          'Press Test connection. Dextr opens the connection, closes it again, and reports exactly what happened.',
          'Press Save connection. It appears in the rail; click it to open it.',
        ]),
        DocsNote(
          title: 'Nothing to hand? Start with SQLite',
          description:
              'A SQLite connection is one file on this machine. Pick the file '
              'and you have a working connection with no server, no port and '
              'no password — the fastest way to see the whole workspace do '
              'something.',
        ),
      ],
    ),
    DocsSection(
      id: 'test-first',
      title: 'Test before you save',
      blocks: <DocsBlock>[
        DocsProse(
          'Test connection is the cheapest thing on the form. It uses exactly '
          'the values in front of you, so a failure tells you which field is '
          'wrong while you are still looking at it — rather than after the '
          'connection is saved, opened, and failing from the rail.',
        ),
        DocsBullets(<String>[
          'A refused connection is usually the host or the port.',
          'An authentication failure is the username, the password, or the database the credentials are checked against.',
          'A timeout on a remote host is usually a firewall or a VPN you are not on.',
          'A TLS error means the server wants a different SSL mode than the one selected.',
        ]),
      ],
    ),
    DocsSection(
      id: 'open-something',
      title: 'Open something',
      blocks: <DocsBlock>[
        DocsProse(
          'Click the connection in the rail. Its tables, collections or '
          'buckets appear indented under it. Click one and it opens in a tab, '
          'on Browse — or on Vectors if it is a vector collection, because '
          'the plot is what that connection is for.',
        ),
        DocsProse(
          'From there: page through the rows, switch to Query to write SQL, '
          'switch to Schema to read the column types, or press Export to put '
          'what you are looking at into a file.',
        ),
      ],
    ),
  ],
);

const _connections = DocsChapter(
  id: 'connections',
  group: DocsGroup.connect,
  title: 'How connections work',
  summary:
      'What every connection form has in common, where your credentials go, '
      'and what each kind of source can do once it is open.',
  sections: <DocsSection>[
    DocsSection(
      id: 'anatomy',
      title: 'Every form has the same shape',
      blocks: <DocsBlock>[
        DocsProse(
          'Nine backends, one arrangement — configure, verify, save — because '
          'that is the order the work happens in.',
        ),
        DocsFacts(<DocsFact>[
          DocsFact(
            'Connection name',
            'Required. What the rail calls this connection.',
          ),
          DocsFact(
            'The backend fields',
            'Host, file, endpoint, keys. Only what this source needs.',
          ),
          DocsFact(
            'Test connection',
            'Opens it now and reports the result. Absent for sources with nothing to ping, such as a list of saved HTTP calls.',
          ),
          DocsFact(
            'Save connection',
            'Writes the record, and puts the secrets in the keychain.',
          ),
        ]),
        DocsProse(
          'Validation lands on the field it belongs to rather than in a '
          'summary at the top, and a combination that cannot work — a remote '
          'host with encryption switched off, say — is called out beside the '
          'decision that caused it.',
        ),
      ],
    ),
    DocsSection(
      id: 'credentials',
      title: 'Where credentials live',
      blocks: <DocsBlock>[
        DocsProse(
          'Passwords, access keys, tokens and service-account keys go into the '
          'operating system keychain — Keychain on macOS, the Credential '
          'Manager on Windows, the Secret Service on Linux. The connection '
          'record beside it holds only the non-secret half: name, host, port, '
          'database, options.',
        ),
        DocsBullets(<String>[
          'Nothing secret is written into the connection file, so a copied config leaks no credential.',
          'Deleting a connection deletes its keychain entry first, then the record. That order matters: the record is the only thing that knows the name of its secret.',
          'A secret left behind by an older version is swept away on launch, so nothing accumulates that nothing can name.',
        ]),
      ],
    ),
    DocsSection(
      id: 'managing',
      title: 'Editing, disconnecting, deleting',
      blocks: <DocsBlock>[
        DocsProse(
          'The same three actions appear on every connection row in the rail '
          'and on the open connection in the workspace bar.',
        ),
        DocsFacts(<DocsFact>[
          DocsFact(
            'Edit connection',
            'Reopens the form with the saved values. Leave a password field untouched to keep the stored one.',
          ),
          DocsFact(
            'Disconnect',
            'Closes the socket and the tabs for that connection. The saved connection stays.',
          ),
          DocsFact(
            'Delete connection',
            'Removes the record and its credentials from this machine, after a confirmation. Nothing inside the database itself is touched.',
          ),
        ]),
      ],
    ),
    DocsSection(
      id: 'what-each-can-do',
      title: 'What each source can do',
      blocks: <DocsBlock>[
        DocsProse(
          'Each connector declares what it supports and the interface follows. '
          'This table is why a view is dimmed for one source and live for '
          'another.',
        ),
        DocsTable(
          label: 'Capabilities by source',
          headers: <String>[
            'Source',
            'Browse',
            'Raw query',
            'Write',
            'Schema',
            'Other',
          ],
          rows: <List<String>>[
            <String>[
              'SQLite',
              'yes',
              'SQL',
              'yes',
              'read and change',
              'transactions',
            ],
            <String>[
              'PostgreSQL',
              'yes',
              'SQL',
              'yes',
              'read and change',
              'transactions',
            ],
            <String>[
              'MySQL',
              'yes',
              'SQL',
              'yes',
              'read and change',
              'transactions',
            ],
            <String>[
              'MongoDB',
              'yes',
              'filter or pipeline',
              'yes',
              'inferred from a sample',
              '—',
            ],
            <String>[
              'Firestore',
              'yes',
              'no',
              'yes',
              'inferred from a sample',
              'multi-project',
            ],
            <String>[
              'S3 / MinIO',
              'yes',
              'no',
              'objects',
              'no',
              'file browser, presigned URLs',
            ],
            <String>[
              'REST API',
              'saved calls',
              'METHOD path',
              'no',
              'no',
              'ad-hoc requests',
            ],
            <String>[
              'GraphQL API',
              'saved calls',
              'a query document',
              'no',
              'no',
              'ad-hoc queries',
            ],
            <String>[
              'Vector DB',
              'yes',
              'vector search',
              'no',
              'read',
              'the Vectors plot',
            ],
          ],
        ),
      ],
    ),
  ],
);

// ---------------------------------------------------------------------------
// Connections
// ---------------------------------------------------------------------------

const _sqlSources = DocsChapter(
  id: 'sql-sources',
  group: DocsGroup.connect,
  title: 'SQLite, PostgreSQL, MySQL',
  summary:
      'The three SQL sources: what to type, and what the SSL choice actually '
      'buys you.',
  sections: <DocsSection>[
    DocsSection(
      id: 'sqlite',
      title: 'SQLite — one file, no server',
      blocks: <DocsBlock>[
        DocsProse(
          'Pick a .db, .sqlite or .sqlite3 file and you are connected. The '
          'file is opened where it sits — nothing is copied, and nothing is '
          'written unless you write it.',
        ),
        DocsBullets(<String>[
          'The path is filled in by the picker and shown read-only. A path typed by hand that does not exist fails later with a worse message.',
          'On macOS, choosing the file also grants Dextr permission to reopen it after a restart. Move or rename the file and you will be asked for it again.',
          'Full SQL, writes, schema changes and transactions are all available.',
        ]),
      ],
    ),
    DocsSection(
      id: 'postgres',
      title: 'PostgreSQL — fields or a URI',
      blocks: <DocsBlock>[
        DocsProse(
          'Type the server out field by field, or switch the form to URI and '
          'paste the connection string your provider gave you. A pasted URI is '
          'parsed back into the fields when you test or save, so you can see '
          'what it actually said.',
        ),
        DocsCode(
          'postgresql://reader:secret@db.example.com:5432/analytics',
          language: 'text',
        ),
        DocsFacts(<DocsFact>[
          DocsFact(
            'Host and port',
            '5432 unless your provider says otherwise.',
          ),
          DocsFact(
            'Database',
            'The database to open. Not the schema — schemas appear as part of each object name.',
          ),
          DocsFact(
            'Username and password',
            'The password goes to the keychain.',
          ),
          DocsFact('SSL mode', 'disable, require or verifyFull.'),
        ]),
        DocsTable(
          label: 'What each PostgreSQL SSL mode does',
          headers: <String>['Mode', 'What you get'],
          rows: <List<String>>[
            <String>[
              'disable',
              'Plain TCP. Right for a database on this machine.',
            ],
            <String>[
              'require',
              'Encrypted, but the certificate is not checked.',
            ],
            <String>[
              'verifyFull',
              'Encrypted, with the certificate and the host name verified. Use this across any network you do not control.',
            ],
          ],
        ),
      ],
    ),
    DocsSection(
      id: 'mysql',
      title: 'MySQL — and a limit worth knowing',
      blocks: <DocsBlock>[
        DocsProse(
          'Host, port 3306, database, username, password. The SSL choice here '
          'is disable or require, and the difference between them is smaller '
          'than it looks.',
        ),
        DocsNote(
          kind: DocsNoteKind.danger,
          title: 'MySQL over TLS is encrypted but not authenticated',
          description:
              'The bundled MySQL driver accepts any certificate for any name, '
              'so "require" hides your traffic from an observer without '
              'proving you reached the right server. On a network you do not '
              'control, reach the database through an SSH tunnel or a VPN '
              'instead.',
        ),
        DocsProse(
          'Dextr says this where the decision is made, not in a footnote: pick '
          'disable for a remote host and the form tells you the password is '
          'about to cross the network in the clear.',
        ),
      ],
    ),
  ],
);

const _documentSources = DocsChapter(
  id: 'document-sources',
  group: DocsGroup.connect,
  title: 'MongoDB and Firestore',
  summary: 'Two document stores, and how each one is reached.',
  sections: <DocsSection>[
    DocsSection(
      id: 'mongodb',
      title: 'MongoDB',
      blocks: <DocsBlock>[
        DocsFacts(<DocsFact>[
          DocsFact('Host and port', '27017 for a local mongod.'),
          DocsFact(
            'Database',
            'The database to open, and the one your credentials are checked against. admin is the usual answer for a server-wide user.',
          ),
          DocsFact(
            'Username and password',
            'Leave both empty for a mongod running without authentication.',
          ),
          DocsFact(
            'Connect over TLS',
            'Required by Atlas. Usually off for a local mongod.',
          ),
        ]),
        DocsProse(
          'Collections appear in the rail. Browse pages through documents, and '
          'the Schema view infers columns from a sample of them, so a field '
          'that only some documents carry is shown with how often it appears.',
        ),
      ],
    ),
    DocsSection(
      id: 'firestore',
      title: 'Firestore',
      blocks: <DocsBlock>[
        DocsProse(
          'Firestore is reached over its REST API, and there are two ways in.',
        ),
        DocsFacts(<DocsFact>[
          DocsFact(
            'Service account',
            'A real project. Pick the JSON key file, and give the project ID and the database ID — "(default)" unless you made another.',
          ),
          DocsFact(
            'Emulator',
            'A local emulator, with no credentials at all. Give the host and port the emulator printed on startup, such as localhost:8080.',
          ),
        ]),
        DocsProse(
          'One connection per project, so several projects are several '
          'connections in the rail rather than a mode you switch. Firestore '
          'has no raw query view here: documents are browsed and edited, and '
          'the Query segment stays dimmed.',
        ),
      ],
    ),
  ],
);

const _objectStorage = DocsChapter(
  id: 'object-storage',
  group: DocsGroup.connect,
  title: 'S3 and MinIO',
  summary: 'One connection kind for AWS S3 and everything that speaks its API.',
  sections: <DocsSection>[
    DocsSection(
      id: 's3-fields',
      title: 'The fields',
      blocks: <DocsBlock>[
        DocsFacts(<DocsFact>[
          DocsFact(
            'Endpoint',
            'The host only — no scheme and no bucket. s3.amazonaws.com for AWS, localhost for a local MinIO.',
          ),
          DocsFact(
            'Port',
            'Leave it blank to use the protocol default. MinIO usually listens on 9000.',
          ),
          DocsFact('Region', 'us-east-1 unless your bucket says otherwise.'),
          DocsFact(
            'Access key ID and secret access key',
            'The secret goes to the keychain.',
          ),
          DocsFact('Session token', 'Only for temporary STS credentials.'),
          DocsFact(
            'Use HTTPS',
            'On for AWS and most hosted S3. Off for a local MinIO serving plain HTTP.',
          ),
        ]),
      ],
    ),
    DocsSection(
      id: 's3-what-you-get',
      title: 'What you get once it opens',
      blocks: <DocsBlock>[
        DocsProse(
          'Buckets appear in the rail, and opening one gives you the file '
          'browser rather than a grid of keys: folders, files, sizes and '
          'modified dates, with a path you can walk back up.',
        ),
        DocsBullets(<String>[
          'Upload, download, preview, rename, move, copy, delete, and make a folder.',
          'Copy a share link — a presigned URL, valid for an hour by default — for anything you can read.',
          'Preview images, text, code, CSV, XLSX, DOCX and PDF facts without leaving the app.',
        ]),
      ],
    ),
  ],
);

const _httpSources = DocsChapter(
  id: 'http-sources',
  group: DocsGroup.connect,
  title: 'REST and GraphQL',
  summary:
      'Turn the endpoints you keep re-typing into saved calls that return rows.',
  sections: <DocsSection>[
    DocsSection(
      id: 'rest',
      title: 'REST — a base URL and a list of calls',
      blocks: <DocsBlock>[
        DocsProse(
          'Give the base URL, then describe the calls you care about as a JSON '
          'array. Each entry becomes a row in the rail that you can open like '
          'a table.',
        ),
        DocsCode(r'''[
  {"name": "Users",    "method": "GET",  "path": "/users"},
  {"name": "User #1",  "method": "GET",  "path": "/users/1"},
  {"name": "New user", "method": "POST", "path": "/users",
   "body": "{\"name\": \"Alice\"}"}
]''', language: 'json'),
        DocsFacts(<DocsFact>[
          DocsFact('name', 'Required. What the rail calls this operation.'),
          DocsFact('method', 'GET unless you say otherwise.'),
          DocsFact('path', 'Appended to the base URL.'),
          DocsFact('headers', 'Extra headers for this one call, as an object.'),
          DocsFact('body', 'JSON text to send.'),
          DocsFact(
            'rowsPath',
            'A dot-path to the array inside the response — "data.users" — for APIs that wrap their list in an envelope.',
          ),
        ]),
        DocsNote(
          title: 'A bad operations list is caught on save',
          description:
              'This array is the whole object tree for the connection, so a '
              'typo would otherwise show up as an empty rail with no '
              'explanation. The form validates it before it will save.',
        ),
      ],
    ),
    DocsSection(
      id: 'graphql',
      title: 'GraphQL — one endpoint, saved queries',
      blocks: <DocsBlock>[
        DocsProse(
          'Give the single URL every query is posted to, then the queries. Each '
          'entry needs a name, a query, and the rowsPath where the list of rows '
          'sits in the response.',
        ),
        DocsCode(r'''[
  {"name": "Countries",
   "query": "{ countries { code name } }",
   "rowsPath": "countries"}
]''', language: 'json'),
        DocsProse(
          'Variables can be saved with an operation as a "variables" object, '
          'and overridden when it runs.',
        ),
      ],
    ),
    DocsSection(
      id: 'http-auth',
      title: 'Authentication',
      blocks: <DocsBlock>[
        DocsProse(
          'REST and GraphQL ask the same question, so they share the same four '
          'answers. Whichever you pick, the value is kept in the keychain and '
          'never in the connection file.',
        ),
        DocsTable(
          label: 'HTTP authentication modes',
          headers: <String>['Mode', 'What is sent'],
          rows: <List<String>>[
            <String>[
              'None',
              'Nothing. A public endpoint, or one behind a network you are already on.',
            ],
            <String>['Bearer token', 'Authorization: Bearer …'],
            <String>['API key header', 'A header you name, such as X-API-Key.'],
            <String>[
              'Basic auth',
              'Authorization: Basic …, the base64 of user:password.',
            ],
          ],
        ),
      ],
    ),
    DocsSection(
      id: 'http-adhoc',
      title: 'One-off requests',
      blocks: <DocsBlock>[
        DocsProse(
          'You do not have to save a call to make one. Open the Query view on '
          'an HTTP connection and send a request directly: the first line is '
          'the method and the path, and anything after it is the body.',
        ),
        DocsCode('GET /users?active=true', language: 'http'),
        DocsProse(
          'For GraphQL, the Query view takes the query document itself. Either '
          'way the response comes back as rows in the results table, with the '
          'HTTP status reported beside them.',
        ),
      ],
    ),
  ],
);

const _vectorSources = DocsChapter(
  id: 'vector-sources',
  group: DocsGroup.connect,
  title: 'Vector databases',
  summary:
      'One connection kind for four engines, three ways of reaching them, and '
      'one deliberate restriction.',
  sections: <DocsSection>[
    DocsSection(
      id: 'engines',
      title: 'Four engines, one form',
      blocks: <DocsBlock>[
        DocsProse(
          'Qdrant, Chroma, Pinecone and Weaviate disagree about almost every '
          'name — points, embeddings, vectors, objects — but they agree about '
          'the shape of the thing: an id, an array of floats, and some payload '
          'beside it. So the engine is a field on the connection rather than a '
          'kind of its own, and the two choices at the top of the form decide '
          'what the rest of it asks for.',
        ),
        DocsTable(
          label: 'Vector engines and the modes each supports',
          headers: <String>['Engine', 'Local', 'Cloud', 'File', 'Reached by'],
          rows: <List<String>>[
            <String>[
              'Qdrant',
              'yes',
              'yes',
              'no',
              'REST, with an api-key header',
            ],
            <String>[
              'Chroma',
              'yes',
              'yes',
              'yes',
              'REST — v2, falling back to v1',
            ],
            <String>[
              'Pinecone',
              'no',
              'yes',
              'no',
              'the control plane, then one host per index',
            ],
            <String>[
              'Weaviate',
              'yes',
              'yes',
              'no',
              'REST to list, GraphQL to search',
            ],
          ],
        ),
        DocsProse(
          'A mode an engine does not have is shown disabled with the reason on '
          'it, rather than quietly missing.',
        ),
      ],
    ),
    DocsSection(
      id: 'vector-modes',
      title: 'Local, Cloud, File',
      blocks: <DocsBlock>[
        DocsFacts(<DocsFact>[
          DocsFact(
            'Local',
            'A server you are running — Docker, or a binary on this machine. Give the URL; a credential only if you started it with authentication on.',
          ),
          DocsFact(
            'Cloud',
            'A hosted endpoint reached with a credential. Pinecone takes its control plane URL and looks up the per-index hosts itself.',
          ),
          DocsFact(
            'File',
            'A Chroma persist directory on disk, opened with no server running at all.',
          ),
        ]),
        DocsProse(
          'File mode is Chroma only, and not as a preference. Chroma persists a '
          'chroma.sqlite3 catalogue beside an hnswlib index, both of which '
          'Dextr can read directly. Qdrant keeps its segments in RocksDB and '
          'Weaviate in an LSM tree — neither is readable without the engine '
          'running — and Pinecone is hosted only.',
        ),
        DocsProse(
          'Chroma also has tenants and databases; leave them empty for '
          'default_tenant and default_database. Pinecone has a namespace; '
          'leave it empty for the default one.',
        ),
      ],
    ),
    DocsSection(
      id: 'vector-read-only',
      title: 'Read-only, on purpose',
      blocks: <DocsBlock>[
        DocsNote(
          title: 'A vector connection browses and searches. It never writes.',
          description:
              'Writing a vector means knowing which embedding model produced '
              'the rest of the collection, and that is not something a client '
              'can find out. So Dextr reads.',
        ),
        DocsProse(
          'For the same reason, query text is never embedded for you. Text '
          'search is literal, and vector search takes a vector you supply or a '
          'point that already exists — a query embedded by the wrong model '
          'returns confident nonsense.',
        ),
      ],
    ),
  ],
);

// ---------------------------------------------------------------------------
// Working with data
// ---------------------------------------------------------------------------

const _browse = DocsChapter(
  id: 'browse',
  group: DocsGroup.work,
  title: 'Browsing rows',
  summary:
      'Read a page at a time, edit a row in a form, and know what you are looking at.',
  sections: <DocsSection>[
    DocsSection(
      id: 'reading',
      title: 'A page at a time',
      blocks: <DocsBlock>[
        DocsProse(
          'Browse fetches one page of rows and draws every one of them. The '
          'toolbar tells you which rows you have — "rows 101–200" — and moves '
          'you a page at a time.',
        ),
        DocsBullets(<String>[
          'Refresh reloads the current page.',
          'The arrows step back and forward. They stop being available at the ends rather than fetching an empty page.',
          'Page size comes from Settings, and is 100 rows by default.',
          'Numbers line up against the right edge and everything else against the left, so a column of figures is comparable at a glance.',
        ]),
        DocsProse(
          'An empty table still shows its columns: the schema knows them even '
          'when no row does, and a table with nothing in it should not look '
          'broken.',
        ),
      ],
    ),
    DocsSection(
      id: 'editing',
      title: 'Inserting and editing',
      blocks: <DocsBlock>[
        DocsProse(
          'Click a row to open it in a form built from the schema — one field '
          'per column, each parsed into the type that column declares, so "3" '
          'reaches an integer column as a number.',
        ),
        DocsFacts(<DocsFact>[
          DocsFact(
            'Insert row',
            'Opens an empty form. A field left empty stores NULL.',
          ),
          DocsFact(
            'Editing a row',
            'Only the columns you actually change are written back.',
          ),
          DocsFact(
            'Primary keys',
            'The update is addressed by the primary key the schema reports. A table without one cannot be edited safely, and Dextr will say so instead of guessing.',
          ),
        ]),
        DocsNote(
          title: 'Deleting rows',
          description:
              'Objects in a bucket have a delete action on the row itself. For '
              'a SQL table, deleting is a statement you write in the Query '
              'view — a click that removes a row from a production table is '
              'not an accident this app will help you have.',
        ),
      ],
    ),
    DocsSection(
      id: 'browse-object-stores',
      title: 'Object stores browse differently',
      blocks: <DocsBlock>[
        DocsProse(
          'Open an S3 or MinIO connection and Browse gives you the file '
          'browser instead of a grid: folders, files, and a path you can walk. '
          'See "Browsing files and objects" for what it can do.',
        ),
      ],
    ),
  ],
);

const _query = DocsChapter(
  id: 'query',
  group: DocsGroup.work,
  title: 'Writing and running queries',
  summary:
      'The editor, what a keystroke runs, completion from your own schema, and '
      'the query language each source expects.',
  sections: <DocsSection>[
    DocsSection(
      id: 'the-editor',
      title: 'The editor and the results',
      blocks: <DocsBlock>[
        DocsProse(
          'The Query view is a syntax-coloured editor above a results table, '
          'with a handle between them you can drag — or focus and move with the '
          'arrow keys — to give either half more room.',
        ),
        DocsProse(
          'Along the bottom of the editor: the caret position, how many '
          'statements the text holds, and what the next run will actually do. '
          'That last one matters, because it changes with your selection.',
        ),
        DocsKeys(<DocsKey>[
          DocsKey(
            <String>['⌘', '↵'],
            'Run the selection, or the statement the caret is in',
            spoken: 'Command Return',
          ),
          DocsKey(
            <String>['⌘', '/'],
            'Comment or uncomment every line the selection touches',
            spoken: 'Command slash',
          ),
          DocsKey(
            <String>['⌘', 'Space'],
            'Ask for completions now',
            spoken: 'Command Space',
          ),
        ]),
        DocsProse(
          'On Windows and Linux, Ctrl is the modifier. Nothing runs on its own: '
          'there is no autorun, and no statement is sent that you did not ask '
          'for.',
        ),
      ],
    ),
    DocsSection(
      id: 'completion',
      title: 'Completion that knows your schema',
      blocks: <DocsBlock>[
        DocsProse(
          'Suggestions come from the connection itself — its tables, and the '
          'columns of the tables the statement you are writing names. The table '
          'open in the tab is offered first, and its columns are available '
          'before you have written a FROM clause at all.',
        ),
        DocsBullets(<String>[
          'Tab or Enter takes the highlighted suggestion.',
          'The right arrow takes the grey hint written ahead of the caret.',
          'Escape dismisses the list.',
          'A list that opened on its own never eats a keystroke that would have written code: with nothing typed, Enter is still a newline.',
        ]),
      ],
    ),
    DocsSection(
      id: 'query-languages',
      title: 'What to write, by source',
      blocks: <DocsBlock>[
        DocsProse(
          'Query means "the raw thing this backend understands", which is not '
          'SQL everywhere.',
        ),
        DocsTable(
          label: 'The query language each source expects',
          headers: <String>['Source', 'Write'],
          rows: <List<String>>[
            <String>[
              'SQLite, PostgreSQL, MySQL',
              'SQL. Several statements separated by semicolons; the caret picks which one runs.',
            ],
            <String>[
              'MongoDB',
              'collection:<name>: followed by a JSON filter or an aggregation pipeline.',
            ],
            <String>[
              'REST',
              'METHOD path on the first line, an optional JSON body after it.',
            ],
            <String>['GraphQL', 'A query document.'],
            <String>[
              'Vector DB',
              'Vector search, from the Vectors view rather than here.',
            ],
            <String>['Firestore', 'No raw query. Browse and edit instead.'],
          ],
        ),
        DocsCode(
          r'''collection:users:{"age": {"$gt": 18}}''',
          language: 'text',
        ),
        DocsCode(
          r'''collection:orders:[{"$group": {"_id": "$status", "n": {"$sum": 1}}}]''',
          language: 'text',
        ),
      ],
    ),
    DocsSection(
      id: 'query-results',
      title: 'The results, and getting them out',
      blocks: <DocsBlock>[
        DocsProse(
          'A run reports how long it took and either the rows it returned or '
          'how many it affected. A failure is shown as the error the backend '
          'gave, in full — not a summary of it.',
        ),
        DocsProse(
          'The Export menu beside Run offers two different things: the rows '
          'that came back, and the query that produced them saved as a .sql '
          'file. Exporting the results does not run the query again.',
        ),
      ],
    ),
  ],
);

const _schema = DocsChapter(
  id: 'schema',
  group: DocsGroup.work,
  title: 'Reading a schema',
  summary: 'The columns of one object, and where those columns came from.',
  sections: <DocsSection>[
    DocsSection(
      id: 'columns',
      title: 'What the Schema view shows',
      blocks: <DocsBlock>[
        DocsFacts(<DocsFact>[
          DocsFact('Name', 'The column, as the backend spells it.'),
          DocsFact(
            'Type',
            "The backend's own type label, not a translation of it.",
          ),
          DocsFact('Nullable', 'Whether the column accepts NULL.'),
          DocsFact(
            'Primary key',
            'Marked, because it is what a row edit is addressed by.',
          ),
          DocsFact(
            'Default',
            'The default expression, where the backend reports one.',
          ),
        ]),
        DocsProse(
          'Press Export to save the column list as a file — the same formats '
          'the rest of the app exports in.',
        ),
      ],
    ),
    DocsSection(
      id: 'inferred',
      title: 'Declared schemas and inferred ones',
      blocks: <DocsBlock>[
        DocsProse(
          'A SQL database is asked what its columns are. A document store has '
          'no answer to that question, so Dextr reads a sample of documents and '
          'reports what it found — including how often each field appeared.',
        ),
        DocsNote(
          title: 'An inferred schema is evidence, not a contract',
          description:
              'A field present in 40% of the sample is a real fact about your '
              'data and not a nullable column. Read the frequency before you '
              'write code that depends on the field being there.',
        ),
      ],
    ),
  ],
);

const _files = DocsChapter(
  id: 'files',
  group: DocsGroup.work,
  title: 'Browsing files and objects',
  summary:
      'A real file browser over a bucket: walk it, preview it, move things '
      'around, and share a link.',
  sections: <DocsSection>[
    DocsSection(
      id: 'walking',
      title: 'Walking a bucket',
      blocks: <DocsBlock>[
        DocsProse(
          'A bucket opens as folders and files rather than a flat list of keys. '
          'The path across the top walks back up, and the toolbar acts on where '
          'you are.',
        ),
        DocsBullets(<String>[
          'Filter narrows the entries in the current folder.',
          'Sort by name, size or modified date.',
          'Refresh relists the folder.',
          'New folder creates one.',
          'Export listing saves the folder listing itself as a file — exactly one level, as the table shows it.',
        ]),
      ],
    ),
    DocsSection(
      id: 'file-actions',
      title: 'What you can do to a file',
      blocks: <DocsBlock>[
        DocsProse(
          'Every row carries its actions in a visible menu — never behind a '
          'hover, because a touch screen has none. Only the actions the source '
          'genuinely supports are offered.',
        ),
        DocsFacts(<DocsFact>[
          DocsFact(
            'Preview',
            'Opens the file in the app, without downloading it.',
          ),
          DocsFact('Download', 'Saves it where you choose.'),
          DocsFact(
            'Copy share link',
            'A presigned URL, valid for an hour by default.',
          ),
          DocsFact('Rename, Move to, Copy to', 'Within the same bucket.'),
          DocsFact(
            'Delete',
            'After a confirmation. A folder takes everything beneath it.',
          ),
          DocsFact('Upload', 'Puts a local file into the folder you are in.'),
        ]),
        DocsNote(
          kind: DocsNoteKind.warning,
          title: 'Deleting a folder deletes everything under it',
          description:
              'Object stores have no folders, only key prefixes — so removing '
              'one removes every object that starts with it. Keep "Confirm '
              'before deleting" on in Settings.',
        ),
      ],
    ),
    DocsSection(
      id: 'previews',
      title: 'What preview can show',
      blocks: <DocsBlock>[
        DocsTable(
          label: 'File kinds and how each is previewed',
          headers: <String>['Kind', 'Shown as'],
          rows: <List<String>>[
            <String>['Images', 'The picture.'],
            <String>['Text and code', 'The text, with JSON indented.'],
            <String>['CSV and TSV', 'A table, with the separator it detected.'],
            <String>['XLSX', 'A table per sheet.'],
            <String>['DOCX', 'Its paragraphs.'],
            <String>[
              'PDF',
              'Its facts — version, security, whether it is linearised. Pages are not drawn.',
            ],
            <String>['Video and audio', 'Duration, resolution and container.'],
            <String>[
              'Anything else',
              'Its metadata, and an honest sentence about why there is no picture.',
            ],
          ],
        ),
        DocsProse(
          'Two ways out of any preview: download it, or open it in the '
          'application that does understand it. Opening externally is limited '
          'to document and media extensions on purpose — an object in a bucket '
          'is named by whoever put it there, and an unrestricted extension '
          'would turn "look at this file" into "run this file".',
        ),
        DocsProse(
          'Previews read a capped number of bytes. When a file is larger than '
          'the cap, Dextr says the preview is partial rather than showing you '
          'half a spreadsheet as though it were the whole one.',
        ),
      ],
    ),
  ],
);

const _vectors = DocsChapter(
  id: 'vectors',
  group: DocsGroup.work,
  title: 'Exploring a vector space',
  summary:
      'The plot, the probe, and the difference between "not in this collection" '
      'and "not in the points on screen".',
  sections: <DocsSection>[
    DocsSection(
      id: 'the-plot',
      title: 'The plot',
      blocks: <DocsBlock>[
        DocsProse(
          'Open a vector collection and it lands on Vectors: the collection '
          'projected onto its leading principal components and drawn as a '
          'scatter you can turn. Three axes by default, with a flat 2D plane '
          'one click away.',
        ),
        DocsFacts(<DocsFact>[
          DocsFact('Axes', '2D or 3D.'),
          DocsFact(
            'Colour by',
            'Any payload field, with a legend that writes each value out beside its swatch.',
          ),
          DocsFact('Sample', 'How many points to read and plot.'),
          DocsFact('Refresh', 'Re-reads the sample.'),
        ]),
        DocsNote(
          title: 'Read the variance figure beside the plot',
          description:
              'It says how much of the spread the projection kept. A plot that '
              'kept 12% of it is a picture, not evidence — two points close '
              'together on screen may be nowhere near each other in the real '
              'space.',
        ),
      ],
    ),
    DocsSection(
      id: 'probe',
      title: 'Probe and neighbours',
      blocks: <DocsBlock>[
        DocsProse(
          'The question the pane is built around is "where does this document '
          'sit, and what is near it". Search the collection for some text, pick '
          'a match, and it becomes the probe: its nearest vectors light up '
          'around it with a thread drawn to each, and everything else steps '
          'back.',
        ),
        DocsProse(
          'Any point you click can be made the probe, and its full payload is '
          'listed beside the plot. Raw vector search is there too, behind '
          '"Search by raw vector": paste a JSON array of the right length and '
          'it finds the nearest points to it.',
        ),
      ],
    ),
    DocsSection(
      id: 'text-search-limits',
      title: 'What text search can reach',
      blocks: <DocsBlock>[
        DocsProse(
          'Text search is literal — a substring match, not a semantic one — and '
          'how far it reaches depends on what the engine can do for itself.',
        ),
        DocsTable(
          label: 'Text search support by engine',
          headers: <String>['Engine', 'Searches'],
          rows: <List<String>>[
            <String>['Chroma (file)', 'Full-text over the documents, indexed.'],
            <String>['Chroma (server)', 'Its own document contains filter.'],
            <String>['Weaviate', 'BM25 across every text property.'],
            <String>[
              'Qdrant',
              'Nothing, without a named field carrying a full-text index.',
            ],
            <String>[
              'Pinecone',
              'Nothing — its metadata filters are exact-match only.',
            ],
          ],
        ),
        DocsProse(
          'Where the engine cannot search itself, Dextr filters the points it '
          'has already read and says so. "Nothing in the 1,000 plotted points" '
          'and "nothing in this collection" are different answers, and only '
          'one of them means your document is not there.',
        ),
      ],
    ),
    DocsSection(
      id: 'vector-keys',
      title: 'Driving the plot from the keyboard',
      blocks: <DocsBlock>[
        DocsProse(
          'Focus the plot and it is fully reachable without a mouse. Drag to '
          'rotate, shift-drag to pan and scroll to zoom if you have one.',
        ),
        DocsKeys(<DocsKey>[
          DocsKey(<String>[
            '←',
            '→',
            '↑',
            '↓',
          ], 'Move the selection between points'),
          DocsKey(
            <String>['⇧', '←'],
            'Turn the camera, in 3D',
            spoken: 'Shift and an arrow key',
          ),
          DocsKey(<String>['Home'], 'Select the first point'),
          DocsKey(<String>['End'], 'Select the last point'),
          DocsKey(<String>['+'], 'Zoom in'),
          DocsKey(<String>['-'], 'Zoom out'),
          DocsKey(<String>['Esc'], 'Reset the view'),
        ]),
      ],
    ),
  ],
);

const _export = DocsChapter(
  id: 'export',
  group: DocsGroup.work,
  title: 'Getting data out',
  summary:
      'Six formats, the options that matter for each, and where to find them.',
  sections: <DocsSection>[
    DocsSection(
      id: 'export-where',
      title: 'Where export lives',
      blocks: <DocsBlock>[
        DocsBullets(<String>[
          'Browse — the page on screen, or every row, paged out of the connection.',
          'Query — the result set the last run returned, or the query itself as a .sql file.',
          'Schema — every column of the open object.',
          'File browser — the folder listing, or the ticked rows of it. Individual objects are downloaded rather than exported.',
        ]),
        DocsProse(
          'Nothing is written until you confirm the save dialog, and the file '
          'is built before it is written — so the message afterwards can tell '
          'you whether the row limit was reached.',
        ),
      ],
    ),
    DocsSection(
      id: 'export-formats',
      title: 'The formats',
      blocks: <DocsBlock>[
        DocsTable(
          label: 'Export formats',
          headers: <String>['Format', 'File', 'For'],
          rows: <List<String>>[
            <String>['CSV', '.csv', 'Spreadsheets. Quoted per RFC 4180.'],
            <String>[
              'TSV',
              '.tsv',
              'Messy text — a tab almost never appears in a value, so far less quoting.',
            ],
            <String>[
              'JSON',
              '.json',
              'Scripts. One array of objects, with real JSON types.',
            ],
            <String>[
              'JSON Lines',
              '.jsonl',
              'Streams, log pipelines and jq. The only one you can append to.',
            ],
            <String>[
              'SQL inserts',
              '.sql',
              'Loading the rows into another database.',
            ],
            <String>[
              'Markdown table',
              '.md',
              'Pasting into a ticket or a document.',
            ],
          ],
        ),
      ],
    ),
    DocsSection(
      id: 'export-options',
      title: 'The options, and why they are there',
      blocks: <DocsBlock>[
        DocsProse(
          'Only the options the chosen format actually has are shown. A header '
          'switch beside a JSON export is a control that does nothing, and a '
          'dialog full of those teaches you to stop reading it.',
        ),
        DocsFacts(<DocsFact>[
          DocsFact(
            'Header row',
            'CSV and TSV. Whether the file starts with the column names.',
          ),
          DocsFact(
            'Text for NULL',
            'Delimited and markdown formats. Empty gives a blank cell; set NULL or \\N where an empty string and a missing value must not look the same.',
          ),
          DocsFact('Indent the JSON', 'Readable, and about a third larger.'),
          DocsFact(
            'Byte-order mark',
            'For Excel on Windows, which otherwise reads a UTF-8 file as the local code page and mangles every accented character.',
          ),
          DocsFact(
            'Row limit',
            'For "every row" exports. The ceiling on one file.',
          ),
        ]),
        DocsProse(
          'The format, the header switch and the NULL text have defaults you '
          'can set once in Settings, because whoever exports CSV every day '
          'exports CSV every day.',
        ),
      ],
    ),
  ],
);

// ---------------------------------------------------------------------------
// Reference
// ---------------------------------------------------------------------------

const _settings = DocsChapter(
  id: 'settings',
  group: DocsGroup.reference,
  title: 'Settings',
  summary: 'Every setting, what it changes, and what it is by default.',
  sections: <DocsSection>[
    DocsSection(
      id: 'settings-where',
      title: 'Opening settings',
      blocks: <DocsBlock>[
        DocsProse(
          'The gear beside the Connections heading in the rail — or the gear in '
          'the footer when the rail is collapsed. Nothing on the page has a Save '
          'button: every control applies the moment you change it.',
        ),
      ],
    ),
    DocsSection(
      id: 'appearance',
      title: 'Appearance',
      blocks: <DocsBlock>[
        DocsFacts(<DocsFact>[
          DocsFact(
            'Theme',
            'Neutral, Stone, Gothic, Matcha, Butter, Chocolate or Y2K. Every colour, size and radius in the app resolves through the one you pick. Neutral by default.',
          ),
          DocsFact(
            'Accent',
            "Overrides the theme's accent. Everything derived from it — hover, pressed, muted — is regenerated to match.",
          ),
          DocsFact('Colour mode', 'System, Light or Dark. System by default.'),
          DocsFact(
            'Density',
            'Compact, Balanced or Spacious. How much room a row of data takes; lists and the rail follow the same choice. Compact by default.',
          ),
        ]),
      ],
    ),
    DocsSection(
      id: 'data-settings',
      title: 'Data',
      blocks: <DocsBlock>[
        DocsFacts(<DocsFact>[
          DocsFact(
            'Rows per page',
            '25, 50, 100, 200 or 500. How many rows Browse fetches at a time — and, since every row is drawn, how much work one page is. 100 by default.',
          ),
          DocsFact(
            'Confirm before deleting',
            'Asks first when removing rows, objects or connections. On by default.',
          ),
        ]),
      ],
    ),
    DocsSection(
      id: 'export-defaults',
      title: 'Export defaults',
      blocks: <DocsBlock>[
        DocsProse(
          'What an export dialog opens on: the format, whether a delimited file '
          'starts with column names, and what stands in for NULL. These are the '
          'choices that are the same on every export you do — per-export '
          'details like JSON indenting stay in the dialog.',
        ),
      ],
    ),
    DocsSection(
      id: 'updates',
      title: 'Updates',
      blocks: <DocsBlock>[
        DocsProse(
          'The section says which build you are running. Check for updates asks '
          'the release feed on github.com and reports one of three things: that '
          'this is the newest release, that a newer one exists, or why it could '
          'not tell. Nothing is sent anywhere until you press it — the page does '
          'not phone out when it opens.',
        ),
        DocsProse(
          'When there is a newer release, Update now opens it in your browser '
          'and the command below it installs it. Dextr does not replace itself: '
          'the application lives in /Applications, /opt or %LOCALAPPDATA%, '
          'writing there needs your password, and a database client that could '
          'quietly elevate itself to overwrite its own binary would be a worse '
          'thing to have installed than the update it saves you fetching. '
          'Updating leaves your connections, credentials and settings alone.',
        ),
        DocsNote(
          title: 'If the check keeps failing',
          description:
              'GitHub limits unauthenticated requests per address, so an '
              'office or VPN address shared with other people can reach the '
              'limit without you checking often. The releases page in a '
              'browser always works.',
        ),
      ],
    ),
    DocsSection(
      id: 'reset',
      title: 'Reset',
      blocks: <DocsBlock>[
        DocsProse(
          'Reset to defaults puts theme, accent, colour mode, density, page '
          'size, the delete confirmation and the export defaults back. It asks '
          'first, and it does not touch your connections.',
        ),
      ],
    ),
    DocsSection(
      id: 'reset-application',
      title: 'Reset application',
      blocks: <DocsBlock>[
        DocsProse(
          'The last section of the settings page, and the only irreversible '
          'thing in it. It removes every connection, every password and key '
          'Dextr saved in the system keychain, and every setting — so the next '
          'launch is a first launch. Open tabs close and live connections are '
          'closed on the way. It asks first, and there is no undo: nothing is '
          'exported and no backup is written.',
        ),
        DocsFacts(<DocsFact>[
          DocsFact(
            'Removed',
            'The connections file, the settings file, and every credential under the dextr.secret. prefix in the keychain.',
          ),
          DocsFact(
            'Untouched',
            'Your databases, their contents, and any file or directory a connection merely points at — a SQLite file or a local Chroma folder is your data, not Dextr\'s.',
          ),
          DocsFact(
            'If something survives',
            'A locked or unavailable keychain is reported rather than assumed away: the message says the credentials could not be removed, and stays until you dismiss it.',
          ),
        ]),
      ],
    ),
  ],
);

const _shortcuts = DocsChapter(
  id: 'shortcuts',
  group: DocsGroup.reference,
  title: 'Keyboard and pointer',
  summary:
      'Every shortcut in one place. On Windows and Linux, Ctrl replaces ⌘.',
  sections: <DocsSection>[
    DocsSection(
      id: 'window-keys',
      title: 'Workspace',
      blocks: <DocsBlock>[
        DocsKeys(<DocsKey>[
          DocsKey(
            <String>['⌘', 'B'],
            'Collapse or expand the connections rail',
            spoken: 'Command B',
          ),
          DocsKey(
            <String>['⌘', 'W'],
            'Close the active tab',
            spoken: 'Command W',
          ),
          DocsKey(
            <String>['⌘', '⌥', 'W'],
            'Close every tab',
            spoken: 'Command Option W',
          ),
        ]),
      ],
    ),
    DocsSection(
      id: 'editor-keys',
      title: 'Query editor',
      blocks: <DocsBlock>[
        DocsKeys(<DocsKey>[
          DocsKey(
            <String>['⌘', '↵'],
            'Run the selection, or the statement at the caret',
            spoken: 'Command Return',
          ),
          DocsKey(
            <String>['⌘', '/'],
            'Comment or uncomment the selected lines',
            spoken: 'Command slash',
          ),
          DocsKey(
            <String>['⌘', 'Space'],
            'Ask for completions',
            spoken: 'Command Space',
          ),
          DocsKey(<String>['Tab'], 'Take the highlighted suggestion'),
          DocsKey(
            <String>['↵'],
            'Take the highlighted suggestion, or insert a newline when nothing is highlighted',
            spoken: 'Return',
          ),
          DocsKey(
            <String>['→'],
            'Take the hint written ahead of the caret',
            spoken: 'Right arrow',
          ),
          DocsKey(<String>['Esc'], 'Dismiss the suggestion list'),
        ]),
      ],
    ),
    DocsSection(
      id: 'plot-keys',
      title: 'Vector plot',
      blocks: <DocsBlock>[
        DocsKeys(<DocsKey>[
          DocsKey(<String>[
            '←',
            '→',
            '↑',
            '↓',
          ], 'Move the selection between points'),
          DocsKey(
            <String>['⇧', '←'],
            'Turn the camera, in 3D',
            spoken: 'Shift and an arrow key',
          ),
          DocsKey(<String>['Home'], 'First point'),
          DocsKey(<String>['End'], 'Last point'),
          DocsKey(<String>['+'], 'Zoom in'),
          DocsKey(<String>['-'], 'Zoom out'),
          DocsKey(<String>['Esc'], 'Reset the view'),
        ]),
        DocsProse(
          'With a pointer: drag to rotate, shift-drag to move, scroll to zoom, '
          'click a mark to select it.',
        ),
      ],
    ),
    DocsSection(
      id: 'everywhere',
      title: 'Everywhere else',
      blocks: <DocsBlock>[
        DocsBullets(<String>[
          'Tab moves between controls; a composite control — a segmented control, a rail, a table — is one stop, and the arrow keys move inside it.',
          'Every action reachable with a mouse is reachable from the keyboard. Nothing is hidden behind hover.',
          'A drag handle can be focused and moved with the arrow keys, Home and End.',
        ]),
      ],
    ),
  ],
);

const _security = DocsChapter(
  id: 'security',
  group: DocsGroup.reference,
  title: 'Credentials and safety',
  summary:
      'What is stored where, what leaves this machine, and the two limits worth '
      'knowing before you point Dextr at production.',
  sections: <DocsSection>[
    DocsSection(
      id: 'stored',
      title: 'What is stored, and where',
      blocks: <DocsBlock>[
        DocsFacts(<DocsFact>[
          DocsFact(
            'Secrets',
            'The OS keychain. Passwords, access keys, tokens, service-account keys.',
          ),
          DocsFact(
            'Connection records',
            'A local file: name, kind, host, port, database, options, and a reference to the keychain entry.',
          ),
          DocsFact('Settings', 'A local file. No connection details in it.'),
          DocsFact(
            'Query text',
            'Held in the tab while it is open. Nothing is logged anywhere.',
          ),
        ]),
        DocsProse(
          'Dextr has no account, no sync and no telemetry. It talks to the '
          'sources you configure and to nothing else.',
        ),
      ],
    ),
    DocsSection(
      id: 'transport',
      title: 'Transport',
      blocks: <DocsBlock>[
        DocsProse(
          'Every source that can be encrypted has the choice on its form, and '
          'the form tells you what the choice actually buys. Two limits are '
          'worth reading twice.',
        ),
        DocsNote(
          kind: DocsNoteKind.danger,
          title: 'MySQL: encrypted is not verified',
          description:
              'The bundled driver accepts any certificate for any host name, so '
              'require encrypts the traffic without proving which server you '
              'reached. Across an untrusted network, tunnel instead.',
        ),
        DocsNote(
          kind: DocsNoteKind.warning,
          title: 'Presigned links are bearer credentials',
          description:
              'A share link grants anyone who has it read access to that object '
              'until it expires — an hour by default. Treat it like a password, '
              'not like a path.',
        ),
      ],
    ),
    DocsSection(
      id: 'safe-defaults',
      title: 'The safe defaults you can rely on',
      blocks: <DocsBlock>[
        DocsBullets(<String>[
          'Deleting a connection removes its keychain entry before its record, so no credential is ever orphaned.',
          'Opening a bucket object in another application is restricted to document and media extensions, so a file named to look executable cannot be launched from a preview.',
          'Vector connections never write.',
          'The install scripts verify the published SHA256 digest and accept assets only from the project\'s own release URL.',
          'Deletes ask first, unless you switch that off in Settings.',
        ]),
      ],
    ),
  ],
);

const _troubleshooting = DocsChapter(
  id: 'troubleshooting',
  group: DocsGroup.reference,
  title: 'When something does not work',
  summary: 'The failures people actually hit, and what each one means.',
  sections: <DocsSection>[
    DocsSection(
      id: 'connecting',
      title: 'It will not connect',
      blocks: <DocsBlock>[
        DocsTable(
          label: 'Connection problems and what they mean',
          headers: <String>['What you see', 'What it usually is'],
          rows: <List<String>>[
            <String>[
              'Connection refused',
              'Nothing is listening there. Check the host and the port, and that the server is running.',
            ],
            <String>[
              'A long wait, then a timeout',
              'A firewall, or a VPN you are not on. The port is filtered rather than closed.',
            ],
            <String>[
              'Authentication failed',
              'The username, the password, or — for MongoDB — the database your credentials are checked against.',
            ],
            <String>[
              'A TLS or certificate error',
              'The server wants a different SSL mode than the one selected. Try require, or verifyFull for PostgreSQL.',
            ],
            <String>[
              'Not connected, with no other detail',
              'Open the connection form and press Test connection: it reports the backend\'s own error rather than a summary.',
            ],
          ],
        ),
      ],
    ),
    DocsSection(
      id: 'empty-rail',
      title: 'It connected, but there is nothing in it',
      blocks: <DocsBlock>[
        DocsBullets(<String>[
          'SQL: the user may not be able to see the schema. Check the grants for the user, not just its ability to log in.',
          'REST or GraphQL: the operations array is empty or was rejected. Reopen the form — it validates the JSON and says what is wrong.',
          'Firestore: the project ID or database ID does not match. "(default)" is the database name for most projects.',
          'S3: the credentials may be scoped to one bucket. Listing buckets and reading a bucket are different permissions.',
        ]),
      ],
    ),
    DocsSection(
      id: 'files-and-vectors',
      title: 'Files and vectors',
      blocks: <DocsBlock>[
        DocsFacts(<DocsFact>[
          DocsFact(
            'A SQLite file that stopped opening',
            'It moved, was renamed, or the permission granted when you picked it lapsed. Edit the connection and pick the file again.',
          ),
          DocsFact(
            'A Chroma file connection that will not open',
            'Point it at the persist directory holding chroma.sqlite3, not at the file itself.',
          ),
          DocsFact(
            'Text search finds nothing',
            'Check whether the engine can search at all — Qdrant needs a full-text index and Pinecone cannot. Dextr says which of the two answers you got.',
          ),
          DocsFact(
            'The plot looks like noise',
            'Read the variance figure. A projection that kept little of the spread cannot be read as distance.',
          ),
          DocsFact(
            'A preview says it is partial',
            'The object is larger than the preview cap. Download it to see all of it.',
          ),
        ]),
      ],
    ),
    DocsSection(
      id: 'exports',
      title: 'Exports',
      blocks: <DocsBlock>[
        DocsBullets(<String>[
          'Accented characters look wrong in Excel on Windows — switch the byte-order mark on.',
          'An empty string and a NULL look identical in your CSV — set Text for NULL to something like NULL.',
          'An "every row" export stopped short — the row limit was reached. The message after the export says so; raise the limit and run it again.',
          'SQL inserts name the wrong table — the export uses the qualified name of the object you exported from.',
        ]),
      ],
    ),
    DocsSection(
      id: 'still-stuck',
      title: 'Still stuck',
      blocks: <DocsBlock>[
        DocsProse(
          'Dextr shows the error the backend returned, in full, wherever it can '
          '— in the pane, on the field, or in the toast. That text is the most '
          'useful thing to search for, and the most useful thing to include if '
          'you open an issue on the project.',
        ),
      ],
    ),
  ],
);
