import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/app_settings.dart';
import '../../downloads/presentation/providers.dart';
import '../../downloads/presentation/downloads_page.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(settingsProvider)
      .when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => ErrorPanel(
          message: errorMessage(error),
          retry: () => ref.invalidate(settingsProvider),
        ),
        data: (settings) {
          final busy = ref
              .watch(downloadsControllerProvider)
              .busy
              .contains('settings');
          final controller = ref.read(downloadsControllerProvider.notifier);
          return ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text('外观', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final entry in {
                    AppTheme.system: '跟随系统',
                    AppTheme.light: '浅色',
                    AppTheme.dark: '深色',
                  }.entries)
                    ChoiceChip(
                      label: Text(entry.value),
                      selected: settings.theme == entry.key,
                      onSelected: busy
                          ? null
                          : (_) => controller.theme(entry.key),
                    ),
                ],
              ),
              const SizedBox(height: 32),
              Text('下载', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 16),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.folder_outlined),
                title: const Text('默认保存目录'),
                subtitle: Text(settings.defaultDirectory.displayName),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: busy ? null : controller.chooseDefaultDirectory,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('选择目录'),
                ),
              ),
              const SizedBox(height: 16),
              const Text('新下载采用此目录；已有任务保持创建时的保存位置。取消选择会保留原目录。'),
              if (busy)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: Text('正在保存设置…'),
                ),
            ],
          );
        },
      );
}
