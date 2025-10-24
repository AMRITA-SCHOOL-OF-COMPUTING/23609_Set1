import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'firebase_options.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

// NOTE: You must add your platform Firebase config files (google-services.json for Android,
// GoogleService-Info.plist for iOS) as instructed in the README section below.

// Simple Event Manager single-file Flutter app
// Dependencies: provider: ^6.0.0

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final options = kIsWeb ? DefaultFirebaseOptions.currentPlatform : null;
    await Firebase.initializeApp(options: options);
  } catch (err) {
    // initialization error will appear in logs; continue to run app so UI can show errors
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => EventProvider(),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Event Manager',
        theme: ThemeData(
          brightness: Brightness.light,
          primarySwatch: Colors.indigo,
          useMaterial3: true,
        ),
        home: const MainScreen(),
        // tiny demo route for Firebase Realtime Database
        routes: {
          '/firebase_demo': (_) => const FirebaseDemoScreen(),
        },
      ),
    );
  }
}

// ---------- Models ----------
class EventItem {
  String id;
  String name;
  String venue;
  DateTime dateTime;

  EventItem({
    required this.id,
    required this.name,
    required this.venue,
    required this.dateTime,
  });
}

// ---------- Provider / State Management ----------
class EventProvider extends ChangeNotifier {
  final List<EventItem> _events = [];
  late final DatabaseReference _eventsRef;

  EventProvider() {
    // initialize DB reference and listeners
    try {
      _eventsRef = FirebaseDatabase.instance.ref('events');
      // initial load: listen for child added/changed/removed
      _eventsRef.onChildAdded.listen((ev) {
        final snapshotValue = ev.snapshot.value;
        if (snapshotValue == null) return;
        final map = Map<String, dynamic>.from(snapshotValue as Map);
        final item = _fromMap(map);
        // avoid duplicates
        if (_events.indexWhere((e) => e.id == item.id) == -1) {
          _events.add(item);
          notifyListeners();
        }
      });

      _eventsRef.onChildChanged.listen((ev) {
        final snapshotValue = ev.snapshot.value;
        if (snapshotValue == null) return;
        final map = Map<String, dynamic>.from(snapshotValue as Map);
        final item = _fromMap(map);
        final idx = _events.indexWhere((e) => e.id == item.id);
        if (idx >= 0) {
          _events[idx] = item;
          notifyListeners();
        }
      });

      _eventsRef.onChildRemoved.listen((ev) {
        final id = ev.snapshot.key;
        if (id == null) return;
        _events.removeWhere((e) => e.id == id);
        notifyListeners();
      });
    } catch (err) {
      // If Firebase not initialized or DB not available, fallback to local-only behavior.
    }
  }

  List<EventItem> get events => List.unmodifiable(_events);

  void addEvent(EventItem e) {
    _events.add(e);
    notifyListeners();
    try {
      _eventsRef.child(e.id).set(_toMap(e));
    } catch (err) {
      // ignore write errors locally
    }
  }

  void updateEvent(String id, EventItem newEvent) {
    final idx = _events.indexWhere((it) => it.id == id);
    if (idx >= 0) {
      _events[idx] = newEvent;
      notifyListeners();
      try {
        _eventsRef.child(id).set(_toMap(newEvent));
      } catch (err) {
        // ignore
      }
    }
  }

  void deleteEvent(String id) {
    _events.removeWhere((it) => it.id == id);
    notifyListeners();
    try {
      _eventsRef.child(id).remove();
    } catch (err) {
      // ignore
    }
  }

  // Helper: convert EventItem -> Map for JSON
  Map<String, Object> _toMap(EventItem e) {
    return {
      'id': e.id,
      'name': e.name,
      'venue': e.venue,
      'dateTime': e.dateTime.toUtc().toIso8601String(),
    };
  }

  // Helper: construct EventItem from DB map
  EventItem _fromMap(Map map) {
    final id =
        map['id']?.toString() ?? (map['key']?.toString() ?? evKeyFromMap(map));
    // Accept multiple possible name keys (eventname, name)
    final name =
        (map['name'] ?? map['eventname'] ?? map['eventName'])?.toString() ?? '';
    final venue = (map['venue'] ?? map['location'])?.toString() ?? '';

    final dynamic dateField =
        map['dateTime'] ?? map['date'] ?? map['timestamp'];
    final DateTime dt = _parseDynamicDate(dateField);
    return EventItem(id: id, name: name, venue: venue, dateTime: dt);
  }

  // Try to recover an event key if it's provided as the DB snapshot key inside the map.
  String evKeyFromMap(Map map) {
    if (map.containsKey(r'$key')) return map[r'$key']?.toString() ?? '';
    if (map.containsKey('key')) return map['key']?.toString() ?? '';
    return '';
  }

  DateTime _parseDynamicDate(dynamic v) {
    if (v == null) return DateTime.now();

    // If Firebase server timestamp comes as a map with seconds/nanos
    if (v is Map) {
      // common shapes: {'_seconds':..., '_nanoseconds':...} or {'seconds':..., 'nanoseconds':...}
      final seconds = v['_seconds'] ?? v['seconds'];
      final nanos = v['_nanoseconds'] ?? v['nanoseconds'] ?? 0;
      if (seconds is int || seconds is double) {
        final ms =
            ((seconds is int ? seconds : (seconds as double).toInt()) * 1000) +
                (nanos ~/ 1000000);
        return DateTime.fromMillisecondsSinceEpoch(ms.toInt()).toLocal();
      }
      // fallback
      return DateTime.now();
    }

    // If it's numeric (seconds or milliseconds)
    if (v is int) {
      // Heuristic: if > 1e12 treat as ms, else seconds
      if (v > 1000000000000) {
        return DateTime.fromMillisecondsSinceEpoch(v).toLocal();
      } else {
        return DateTime.fromMillisecondsSinceEpoch(v * 1000).toLocal();
      }
    }
    if (v is double) {
      final iv = v.toInt();
      if (iv > 1000000000000)
        return DateTime.fromMillisecondsSinceEpoch(iv).toLocal();
      return DateTime.fromMillisecondsSinceEpoch(iv * 1000).toLocal();
    }

    // If it's a String, try several parsing strategies
    if (v is String) {
      // 1) ISO-8601
      try {
        final p = DateTime.parse(v);
        return p.toLocal();
      } catch (_) {}

      // 2) Firebase Console human format with 'UTC+offset' like:
      //    "October 23, 2025 at 3:40:11 PM UTC+5:30"
      final utcIndex = v.indexOf(' UTC');
      if (utcIndex != -1) {
        final left = v.substring(0, utcIndex).trim();
        final right = v.substring(utcIndex + 4).trim(); // e.g. +5:30
        try {
          final df = DateFormat("MMMM d, yyyy 'at' h:mm:ss a");
          final localNoOffset = df.parseLoose(left);
          // parse offset
          final m = RegExp(r"([+-])(\d{1,2}):(\d{2})").firstMatch(right);
          if (m != null) {
            final sign = m.group(1) == '-' ? -1 : 1;
            final hours = int.parse(m.group(2)!);
            final mins = int.parse(m.group(3)!);
            final offset = Duration(hours: hours, minutes: mins) * sign;
            // localNoOffset is the wall time at that offset; convert to UTC by subtracting offset
            final utc = localNoOffset.subtract(offset);
            return utc.toLocal();
          }
          return localNoOffset.toLocal();
        } catch (_) {}
      }

      // 3) Try a common readable pattern without UTC
      try {
        final df2 = DateFormat("MMMM d, yyyy 'at' h:mm:ss a");
        final parsed = df2.parseLoose(v);
        return parsed.toLocal();
      } catch (_) {}
    }

    // Fallback
    return DateTime.now();
  }

  List<EventItem> search(String query) {
    if (query.trim().isEmpty) return events;
    final q = query.toLowerCase();
    return _events.where((e) {
      return e.name.toLowerCase().contains(q) ||
          e.venue.toLowerCase().contains(q) ||
          _formatDate(e.dateTime).contains(q);
    }).toList();
  }
}

// ---------- Utility ----------
String _formatDate(DateTime dt) {
  final d = dt.toLocal();
  final month = <String>[
    '',
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec'
  ][d.month];
  final two = (int n) => n.toString().padLeft(2, '0');
  return '${d.day} $month ${d.year} ${two(d.hour)}:${two(d.minute)}';
}

// ---------- Screens ----------
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  bool _isSearching = false;
  String _searchQuery = '';

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<EventProvider>(context);
    final events = provider.search(_searchQuery);

    return Scaffold(
      appBar: AppBar(
        title: _isSearching ? _buildSearchField() : const Text('Event Manager'),
        actions: [
          IconButton(
            icon: Icon(_isSearching ? Icons.close : Icons.search),
            onPressed: () {
              setState(() {
                if (_isSearching) {
                  _isSearching = false;
                  _searchQuery = '';
                } else {
                  _isSearching = true;
                }
              });
            },
          ),
        ],
      ),
      body: events.isEmpty
          ? _emptyState(context)
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: events.length,
              itemBuilder: (context, index) {
                final e = events[index];
                return EventCard(event: e);
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          // add event
          await Navigator.of(context).push(PageRouteBuilder(
            pageBuilder: (context, a1, a2) => const AddEditEventScreen(),
            transitionsBuilder: (context, a1, a2, child) {
              final tween = Tween(begin: const Offset(0, 1), end: Offset.zero)
                  .chain(CurveTween(curve: Curves.easeOutCubic));
              return SlideTransition(position: a1.drive(tween), child: child);
            },
          ));
        },
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildSearchField() {
    return TextField(
      autofocus: true,
      decoration: const InputDecoration(
        hintText: 'Search by name, venue or date...',
        border: InputBorder.none,
      ),
      onChanged: (v) => setState(() => _searchQuery = v),
    );
  }

  Widget _emptyState(BuildContext ctx) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.event_busy, size: 72, semanticLabel: 'No events'),
          const SizedBox(height: 12),
          const Text('No events yet. Tap + to add one.'),
        ],
      ),
    );
  }
}

// ---------------- Firebase demo ----------------
class FirebaseDemoScreen extends StatefulWidget {
  const FirebaseDemoScreen({super.key});

  @override
  State<FirebaseDemoScreen> createState() => _FirebaseDemoScreenState();
}

class _FirebaseDemoScreenState extends State<FirebaseDemoScreen> {
  late DatabaseReference _counterRef;
  int _counter = 0;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _initFirebase();
  }

  Future<void> _initFirebase() async {
    try {
      await Firebase.initializeApp();
      final db = FirebaseDatabase.instance;
      _counterRef = db.ref('demo/counter');

      // listen for changes
      _counterRef.onValue.listen((e) {
        final val = e.snapshot.value;
        setState(() {
          _counter = (val is int) ? val : int.tryParse('$val') ?? 0;
          _initialized = true;
        });
      });
    } catch (err) {
      // ignore for now; show in UI
      setState(() => _initialized = true);
    }
  }

  Future<void> _increment() async {
    await _counterRef.set(_counter + 1);
  }

  Future<void> _reset() async {
    await _counterRef.set(0);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Firebase Realtime DB Demo')),
      body: Center(
        child: _initialized
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Counter value: $_counter',
                      style: const TextStyle(fontSize: 24)),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ElevatedButton(
                          onPressed: _increment,
                          child: const Text('Increment')),
                      const SizedBox(width: 12),
                      ElevatedButton(
                          onPressed: _reset, child: const Text('Reset')),
                    ],
                  )
                ],
              )
            : const CircularProgressIndicator(),
      ),
    );
  }
}

class EventCard extends StatelessWidget {
  final EventItem event;
  const EventCard({super.key, required this.event});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => EventDetailsScreen(eventId: event.id)));
        },
        child: ListTile(
          leading: Hero(
            tag: 'avatar_${event.id}',
            child: CircleAvatar(
              child: Text(event.name.isNotEmpty
                  ? event.name.trim()[0].toUpperCase()
                  : '?'),
            ),
          ),
          title: Text(event.name),
          subtitle: Text('${_formatDate(event.dateTime)} \n${event.venue}'),
          isThreeLine: true,
          trailing: PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'edit') {
                await Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => AddEditEventScreen(event: event)));
              } else if (v == 'delete') {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Delete event?'),
                    content: const Text('This action cannot be undone.'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.of(ctx).pop(false),
                          child: const Text('Cancel')),
                      TextButton(
                          onPressed: () => Navigator.of(ctx).pop(true),
                          child: const Text('Delete')),
                    ],
                  ),
                );
                if (ok == true) {
                  Provider.of<EventProvider>(context, listen: false)
                      .deleteEvent(event.id);
                }
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: Text('Edit')),
              PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ),
      ),
    );
  }
}

class EventDetailsScreen extends StatelessWidget {
  final String eventId;
  const EventDetailsScreen({super.key, required this.eventId});

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<EventProvider>(context);
    final event = provider.events.firstWhere((e) => e.id == eventId);

    return Scaffold(
      appBar: AppBar(title: const Text('Event Details')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Card(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Hero(
                      tag: 'avatar_${event.id}',
                      child: CircleAvatar(
                        radius: 36,
                        child: Text(event.name.isNotEmpty
                            ? event.name[0].toUpperCase()
                            : '?'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                        child: Text(event.name,
                            style: const TextStyle(
                                fontSize: 20, fontWeight: FontWeight.bold))),
                    IconButton(
                        onPressed: () async {
                          await Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) =>
                                  AddEditEventScreen(event: event)));
                        },
                        icon: const Icon(Icons.edit))
                  ],
                ),
                const SizedBox(height: 16),
                Text('Date & Time',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 6),
                Text(_formatDate(event.dateTime)),
                const SizedBox(height: 12),
                Text('Venue', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 6),
                Text(event.venue),
                const SizedBox(height: 20),
                const Divider(),
                const SizedBox(height: 8),
                ElevatedButton.icon(
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Delete event?'),
                        content: const Text('Are you sure you want to delete?'),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.of(ctx).pop(false),
                              child: const Text('Cancel')),
                          TextButton(
                              onPressed: () => Navigator.of(ctx).pop(true),
                              child: const Text('Delete')),
                        ],
                      ),
                    );
                    if (ok == true) {
                      Provider.of<EventProvider>(context, listen: false)
                          .deleteEvent(event.id);
                      Navigator.of(context).pop();
                    }
                  },
                  icon: const Icon(Icons.delete),
                  label: const Text('Delete Event'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.redAccent,
                  ),
                )
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class AddEditEventScreen extends StatefulWidget {
  final EventItem? event;
  const AddEditEventScreen({super.key, this.event});

  @override
  State<AddEditEventScreen> createState() => _AddEditEventScreenState();
}

class _AddEditEventScreenState extends State<AddEditEventScreen> {
  final _formKey = GlobalKey<FormState>();
  late String _name;
  late String _venue;
  late DateTime _dateTime;

  @override
  void initState() {
    super.initState();
    if (widget.event != null) {
      _name = widget.event!.name;
      _venue = widget.event!.venue;
      _dateTime = widget.event!.dateTime;
    } else {
      _name = '';
      _venue = '';
      _dateTime = DateTime.now();
    }
  }

  Future<void> _pickDateTime() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _dateTime,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (date == null) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_dateTime),
    );
    if (time == null) return;
    setState(() {
      _dateTime =
          DateTime(date.year, date.month, date.day, time.hour, time.minute);
    });
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.event != null;
    return Scaffold(
      appBar: AppBar(title: Text(isEdit ? 'Edit Event' : 'Add Event')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: ListView(
            children: [
              TextFormField(
                initialValue: _name,
                decoration: const InputDecoration(labelText: 'Event Name'),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Required' : null,
                onSaved: (v) => _name = v!.trim(),
              ),
              const SizedBox(height: 12),
              TextFormField(
                initialValue: _venue,
                decoration: const InputDecoration(labelText: 'Venue'),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Required' : null,
                onSaved: (v) => _venue = v!.trim(),
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Date & Time'),
                subtitle: Text(_formatDate(_dateTime)),
                trailing: TextButton(
                  onPressed: _pickDateTime,
                  child: const Text('Select'),
                ),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _save,
                child: Text(isEdit ? 'Save Changes' : 'Save Event'),
              )
            ],
          ),
        ),
      ),
    );
  }

  void _save() async {
    if (!_formKey.currentState!.validate()) return;
    _formKey.currentState!.save();

    final provider = Provider.of<EventProvider>(context, listen: false);
    final id =
        widget.event?.id ?? DateTime.now().millisecondsSinceEpoch.toString();
    final newEvent =
        EventItem(id: id, name: _name, venue: _venue, dateTime: _dateTime);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm'),
        content: Text('Save event "$_name"?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Save')),
        ],
      ),
    );

    if (confirmed != true) return;

    if (widget.event == null) {
      provider.addEvent(newEvent);
    } else {
      provider.updateEvent(widget.event!.id, newEvent);
    }

    Navigator.of(context).pop();
  }
}

// ---------- End of File ----------
