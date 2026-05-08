# Flutter Mobile App Best Practices

## Material Design 3

### Why Material 3?

- Native-optimized components
- Consistent design language
- Built-in accessibility
- Automatic theming system
- Better performance than custom widgets

### Key Material 3 Components Used

#### 1. **Card Widgets**

```dart
// Old (Custom)
Container(
  decoration: BoxDecoration(
    color: Colors.white,
    borderRadius: BorderRadius.circular(8),
    boxShadow: [...],
  ),
  child: ...,
)

// New (Material 3)
Card.filled(
  child: ...,
)
```

#### 2. **ListTile**

```dart
Card.filled(
  child: ListTile(
    leading: CircleAvatar(...),
    title: Text(...),
    subtitle: Text(...),
    trailing: Icon(...),
  ),
)
```

#### 3. **Buttons**

```dart
// Filled button for primary actions
FilledButton.icon(
  icon: Icon(Icons.add),
  label: Text('Add'),
  onPressed: () {},
)

// Tonal button for secondary actions
FilledButton.tonalIcon(
  icon: Icon(Icons.back),
  label: Text('Back'),
  onPressed: () {},
)

// Text button for tertiary actions
TextButton(
  onPressed: () {},
  child: Text('Cancel'),
)
```

#### 4. **Theme Integration**

```dart
final theme = Theme.of(context);
final colorScheme = theme.colorScheme;

// Use color scheme
Container(
  color: colorScheme.primaryContainer,
  child: Icon(
    Icons.person,
    color: colorScheme.onPrimaryContainer,
  ),
)

// Use text theme
Text(
  'Title',
  style: theme.textTheme.titleMedium,
)
```

## Performance Optimization

### 1. **Camera Stream Management**

#### Throttling Strategy

```dart
// Time-based throttling
DateTime? _lastProcessedTime;
static const _processingInterval = Duration(milliseconds: 300);

// Frame skipping
int _skipFrameCount = 0;
static const _skipFrames = 2;

// Implementation
if (_lastProcessedTime == null ||
    now.difference(_lastProcessedTime!) > _processingInterval) {
  _skipFrameCount++;
  if (_skipFrameCount > _skipFrames) {
    // Process frame
  }
}
```

#### Resolution Management

```dart
controller = CameraController(
  description,
  ResolutionPreset.medium, // Balance quality and performance
  enableAudio: false,       // Disable audio for face detection
);
```

### 2. **ML Model Optimization**

#### Thread Management

```dart
recognizer = Recognizer(numThreads: 2); // Use 2-4 threads max
```

#### Inference Optimization

```dart
// Limit input size
static const int inputWidth = 112;
static const int inputHeight = 112;

// Reuse buffers
Float32List reshapedArray = Float32List(1 * height * width * channels);
```

### 3. **Memory Management**

#### Proper Disposal

```dart
@override
void dispose() {
  controller?.dispose();
  faceDetector.close();
  recognizer.close();
  super.dispose();
}
```

#### Image Buffer Management

```dart
// Don't create new images unnecessarily
img.Image? image;

// Reuse when possible
if (_cachedImage == null) {
  _cachedImage = Util.convertNV21(frame!);
}
```

### 4. **UI Rendering Optimization**

#### Const Constructors

```dart
const Icon(Icons.person) // Reuses instances
const SizedBox(height: 16) // No rebuild
const Text('Static text')
```

#### Avoid Unnecessary Rebuilds

```dart
// Bad
setState(() {
  // Rebuilds entire widget tree
});

// Good
ValueNotifier<List<Recognition>> recognitions = ValueNotifier([]);

ValueListenableBuilder(
  valueListenable: recognitions,
  builder: (context, value, child) {
    return CustomPaint(painter: FacePainter(value));
  },
)
```

## Code Organization

### File Structure

```
lib/
├── main.dart
├── Screens/
│   ├── HomeScreen.dart
│   ├── RecognitionScreen.dart
│   ├── RegistrationScreen.dart
│   └── RegisteredFacesScreen.dart
├── ML/
│   ├── Recognition.dart
│   └── Recognizer.dart
├── DB/
│   └── DatabaseHelper.dart
└── Util.dart
```

### Naming Conventions

- **Files**: PascalCase (HomeScreen.dart)
- **Classes**: PascalCase (HomeScreen)
- **Variables**: camelCase (isBusy)
- **Constants**: camelCase with static const (inputWidth)
- **Private**: Prefix with \_ (\_lastProcessedTime)

## State Management

### For Simple Apps

```dart
// StatefulWidget with setState
class MyWidget extends StatefulWidget {
  @override
  State<MyWidget> createState() => _MyWidgetState();
}
```

### For Medium Apps

```dart
// ValueNotifier
ValueNotifier<int> counter = ValueNotifier(0);

ValueListenableBuilder(
  valueListenable: counter,
  builder: (context, value, child) {
    return Text('$value');
  },
)
```

## Error Handling

### Async Operations

```dart
try {
  await controller.initialize();
} catch (e) {
  print('Error initializing camera: $e');
  if (mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Camera error: $e')),
    );
  }
}
```

### Null Safety

```dart
// Check before use
if (controller?.value.isInitialized ?? false) {
  // Safe to use controller
}

// Use null-aware operators
final width = controller?.value.previewSize?.width ?? 0;
```

## Platform-Specific Code

### Image Format

```dart
imageFormatGroup: Platform.isAndroid
    ? ImageFormatGroup.nv21
    : ImageFormatGroup.yuv420,
```

### Image Conversion

```dart
image = Platform.isIOS
    ? Util.convertBGRA8888ToImage(frame!)
    : Util.convertNV21(frame!);
```

## Accessibility

### Semantic Labels

```dart
Semantics(
  label: 'Register new face button',
  child: FilledButton(...),
)
```

### Text Scaling

```dart
// Use theme text styles (auto-scales)
Text(
  'Title',
  style: Theme.of(context).textTheme.titleLarge,
)
```

## Testing Considerations

### Widget Tests

```dart
testWidgets('Home screen displays correctly', (tester) async {
  await tester.pumpWidget(MyApp());
  expect(find.text('Face Recognition Attendance'), findsOneWidget);
});
```

### Performance Tests

```dart
// Monitor frame rendering
await tester.pumpAndSettle();
final binding = WidgetsFlutterBinding.ensureInitialized();
print('Frame duration: ${binding.window.physicalSize}');
```

## Build Optimization

### Release Build

```bash
flutter build apk --release --split-per-abi
flutter build ios --release
```

### Obfuscation

```bash
flutter build apk --obfuscate --split-debug-info=./debug-info
```

### Tree Shaking

- Flutter automatically removes unused code
- Avoid importing entire packages
- Use specific imports

## Security Best Practices

### Asset Protection

```yaml
# pubspec.yaml
flutter:
  assets:
    - assets/
```

### Database Security

```dart
// Use path_provider for secure storage
final directory = await getApplicationDocumentsDirectory();
final path = join(directory.path, 'faces.db');
```

## Debugging Tools

### Performance Overlay

```dart
MaterialApp(
  showPerformanceOverlay: true, // Show FPS
)
```

### Debug Paint

```dart
debugPaintSizeEnabled = true;
debugPaintLayerBordersEnabled = true;
```

### DevTools

```bash
flutter pub global activate devtools
flutter pub global run devtools
```

## Common Pitfalls to Avoid

1. **Processing every camera frame**
   - Solution: Throttle and skip frames

2. **Heavy operations on UI thread**
   - Solution: Use isolates or compute()

3. **Not disposing resources**
   - Solution: Always implement dispose()

4. **Rebuilding entire tree**
   - Solution: Use const and ValueNotifier

5. **Ignoring platform differences**
   - Solution: Check Platform.isAndroid/isIOS

6. **Memory leaks in camera streams**
   - Solution: Stop stream in dispose()

7. **Not using Material 3 components**
   - Solution: Leverage built-in widgets

## Summary

Following these best practices will result in:

- ✅ Better performance (60 FPS UI)
- ✅ Lower CPU and memory usage
- ✅ Consistent Material 3 design
- ✅ Maintainable codebase
- ✅ Better user experience
- ✅ Efficient resource usage
