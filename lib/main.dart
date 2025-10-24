import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firebase_options.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

// NOTE: You must add your platform Firebase config files (google-services.json for Android,
// GoogleService-Info.plist for iOS) as instructed in the README section below.

// Simple Event Manager single-file Flutter app
// Dependencies: provider: ^6.0.0, cloud_firestore: ^5.0.0

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
        // tiny demo route for Firestore
        routes: {
          '/firestore_demo': (_) => const FirestoreDemoScreen(),
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
  late final CollectionReference _eventsCollection;
  bool _initialized = false;

  EventProvider() {
    // initialize Firestore reference and listeners
    try {
      _eventsCollection = FirebaseFirestore.instance.collection('events');
      // Listen to real-time updates
      _eventsCollection.snapshots().listen((snapshot) {
        _events.clear();
        for (var doc in snapshot.docs) {
          try {
            final item = _fromFirestore(doc);
            _events.add(item);
          } catch (e) {
            // Skip invalid documents
            print('Error parsing document ${doc.id}: $e');
          }
        }
        _initialized = true;
        notifyListeners();
      });
    } catch (err) {
      // If Firebase not initialized or Firestore not available, fallback to local-only behavior.
      print('Firestore initialization error: $err');
    }
  }

  List<EventItem> get events => List.unmodifiable(_events);

  Future<void> addEvent(EventItem e) async {
    _events.add(e);
    notifyListeners();
    try {
      await _eventsCollection.doc(e.id).set(_toFirestore(e));
    } catch (err) {
      print('Error adding event: $err');
      // Remove from local list if Firestore write fails
      _events.removeWhere((event) => event.id == e.id);
      notifyListeners();
    }
  }

  Future<void> updateEvent(String id, EventItem newEvent) async {
    final idx = _events.indexWhere((it) => it.id == id);
    if (idx >= 0) {
      final oldEvent = _events[idx];
      _events[idx] = newEvent;
      notifyListeners();
      try {
        await _eventsCollection.doc(id).update(_toFirestore(newEvent));
      } catch (err) {
        print('Error updating event: $err');
        // Revert on error
        _events[idx] = oldEvent;
        notifyListeners();
      }
    }
  }

  Future<void> deleteEvent(String id) async {
    final idx = _events.indexWhere((it) => it.id == id);
    if (idx >= 0) {
      final removedEvent = _events[idx];
      _events.removeWhere((it) => it.id == id);
      notifyListeners();
      try {
        await _eventsCollection.doc(id).delete();
      } catch (err) {
        print('Error deleting event: $err');
        // Restore on error
        _events.insert(idx, removedEvent);
        notifyListeners();
      }
    }
  }

  // Helper: convert EventItem -> Map for Firestore
  Map<String, Object> _toFirestore(EventItem e) {
    return {
      'id': e.id,
      'name': e.name,
      'venue': e.venue,
      'dateTime': Timestamp.fromDate(e.dateTime.toUtc()),
    };
  }

  // Helper: construct EventItem from Firestore document
  EventItem _fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    final id = doc.id;

    // Accept multiple possible name keys
    final name =
        (data['name'] ?? data['eventname'] ?? data['eventName'])?.toString() ??
            '';
    final venue = (data['venue'] ?? data['location'])?.toString() ?? '';

    final dynamic dateField =
        data['dateTime'] ?? data['date'] ?? data['timestamp'];
    final DateTime dt = _parseDynamicDate(dateField);

    return EventItem(id: id, name: name, venue: venue, dateTime: dt);
  }

  DateTime _parseDynamicDate(dynamic v) {
    if (v == null) return DateTime.now();

    // Firestore Timestamp
    if (v is Timestamp) {
      return v.toDate().toLocal();
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
      if (iv > 1000000000000) {
        return DateTime.fromMillisecondsSinceEpoch(iv).toLocal();
      }
      return DateTime.fromMillisecondsSinceEpoch(iv * 1000).toLocal();
    }

    // If it's a String, try parsing
    if (v is String) {
      try {
        final p = DateTime.parse(v);
        return p.toLocal();
      } catch (_) {
        // Try common date format
        try {
          final df = DateFormat("MMMM d, yyyy 'at' h:mm:ss a");
          final parsed = df.parseLoose(v);
          return parsed.toLocal();
        } catch (_) {}
      }
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

// ---------------- Firestore demo ----------------
class FirestoreDemoScreen extends StatefulWidget {
  const FirestoreDemoScreen({super.key});

  @override
  State<FirestoreDemoScreen> createState() => _FirestoreDemoScreenState();
}

class _FirestoreDemoScreenState extends State<FirestoreDemoScreen> {
  late DocumentReference _counterDoc;
  int _counter = 0;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _initFirestore();
  }

  Future<void> _initFirestore() async {
    try {
      await Firebase.initializeApp();
      final db = FirebaseFirestore.instance;
      _counterDoc = db.collection('demo').doc('counter');

      // listen for changes
      _counterDoc.snapshots().listen((snapshot) {
        if (snapshot.exists) {
          final data = snapshot.data() as Map<String, dynamic>?;
          final val = data?['value'];
          setState(() {
            _counter = (val is int) ? val : int.tryParse('$val') ?? 0;
            _initialized = true;
          });
        } else {
          setState(() {
            _counter = 0;
            _initialized = true;
          });
        }
      });
    } catch (err) {
      print('Firestore init error: $err');
      setState(() => _initialized = true);
    }
  }

  Future<void> _increment() async {
    await _counterDoc.set({'value': _counter + 1});
  }

  Future<void> _reset() async {
    await _counterDoc.set({'value': 0});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Firestore Demo')),
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
                  await Provider.of<EventProvider>(context, listen: false)
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
                      await Provider.of<EventProvider>(context, listen: false)
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
      await provider.addEvent(newEvent);
    } else {
      await provider.updateEvent(widget.event!.id, newEvent);
    }

    Navigator.of(context).pop();
  }
}

// ---------- End of File ----------
