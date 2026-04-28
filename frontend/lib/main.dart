import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'api_client.dart';
import 'app.dart';
import 'providers/pending_jobs_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
    ),
  );

  final api = ApiClient();
  await api.loadToken();
  final pendingJobs = PendingJobsProvider();
  await pendingJobs.load();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: api),
        ChangeNotifierProvider.value(value: pendingJobs),
      ],
      child: const FurniApp(),
    ),
  );
}
