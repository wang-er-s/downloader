import '../data/download_repository.dart' show RepositoryException;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/download_models.dart';
import '../../saved_downloads/presentation/saved_downloads_page.dart';
import 'download_form.dart';
import 'providers.dart';

String bytesLabel(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
}

String statusLabel(DownloadStatus status) => switch (status) {
  DownloadStatus.queued => '等待下载',
  DownloadStatus.running => '下载中',
  DownloadStatus.paused => '已暂停',
  DownloadStatus.waitingRecovery => '等待手动恢复',
  DownloadStatus.publishing => '已下载，待保存',
  DownloadStatus.failed => '下载失败',
  DownloadStatus.completed => '完成',
  DownloadStatus.cancelling => '取消与清理中',
  DownloadStatus.deleting => '文件删除待处理',
};

class DownloadsPage extends ConsumerWidget {
  const DownloadsPage({
    super.key,
    required this.category,
    required this.onCategoryChanged,
  });

  final int category;
  final ValueChanged<int> onCategoryChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(tasksProvider);
    final saved = ref.watch(savedProvider);
    final list = tasks.asData?.value;
    final active = list
        ?.where((t) => t.status != DownloadStatus.completed)
        .length;
    final completed = list
        ?.where((t) => t.status == DownloadStatus.completed)
        .length;
    final labels = [
      '下载中 ${active ?? '—'}',
      '已完成 ${completed ?? '—'}',
      '缓存 ${saved.asData?.value.length ?? '—'}',
    ];
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (var i = 0; i < labels.length; i++)
                ChoiceChip(
                  showCheckmark: false,
                  label: Text(labels[i]),
                  selected: category == i,
                  onSelected: (_) => onCategoryChanged(i),
                ),
            ],
          ),
        ),
        Expanded(
          child: category == 2
              ? const SavedDownloadsPage()
              : tasks.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (error, _) => ErrorPanel(
                    message: errorMessage(error),
                    retry: () {
                      ref.invalidate(tasksProvider);
                      ref
                          .read(downloadsControllerProvider.notifier)
                          .synchronize();
                    },
                  ),
                  data: (all) {
                    final items = all
                        .where(
                          (task) =>
                              (task.status == DownloadStatus.completed) ==
                              (category == 1),
                        )
                        .toList();
                    if (category == 1) {
                      items.sort(
                        (a, b) => (b.completedAt ?? b.updatedAt).compareTo(
                          a.completedAt ?? a.updatedAt,
                        ),
                      );
                    }
                    if (items.isEmpty) {
                      return EmptyPanel(
                        label: category == 0 ? '暂无进行中的下载' : '暂无已完成文件',
                        action: '新建下载',
                        onPressed: () => showDownloadForm(context),
                      );
                    }
                    return ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      itemCount: items.length,
                      itemBuilder: (_, index) =>
                          DownloadCard(task: items[index]),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class EmptyPanel extends StatelessWidget {
  const EmptyPanel({
    super.key,
    required this.label,
    required this.action,
    required this.onPressed,
  });
  final String label, action;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.download_outlined,
            size: 48,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 16),
          Text(label),
          const SizedBox(height: 16),
          FilledButton(onPressed: onPressed, child: Text(action)),
        ],
      ),
    ),
  );
}

class ErrorPanel extends StatelessWidget {
  const ErrorPanel({super.key, required this.message, required this.retry});
  final String message;
  final VoidCallback retry;
  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, semanticsLabel: '读取失败：$message'),
          const SizedBox(height: 16),
          OutlinedButton(onPressed: retry, child: const Text('重试')),
        ],
      ),
    ),
  );
}

Future<bool> confirmAction(
  BuildContext context,
  String title,
  String message,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        scrollable: true,
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认'),
          ),
        ],
      ),
    ) ??
    false;

String completionTimeLabel(DateTime time) {
  final local = time.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

class DownloadCard extends ConsumerWidget {
  const DownloadCard({super.key, required this.task});
  final DownloadTask task;
  Future<void> action(
    BuildContext context,
    WidgetRef ref,
    String action,
  ) async {
    final controller = ref.read(downloadsControllerProvider.notifier);
    switch (action) {
      case 'details':
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('下载详情'),
            scrollable: true,
            content: SelectableText(
              '${task.displayName}\n\n${task.originalUrl}\n\n保存目录：${task.directory.displayName}\n${statusLabel(task.status)}${task.status == DownloadStatus.completed ? '' : '\n速度未知 · 剩余时间未知'}\n${task.lastError?.message ?? ''}',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'),
              ),
            ],
          ),
        );
      case 'cancel':
        if (await confirmAction(
          context,
          '取消下载',
          '停止传输并清理未完成文件。清理失败时保留记录以便处理。',
        )) {
          await controller.cancel(task.id);
        }
      case 'redownload':
        if (await confirmAction(context, '重新下载', '将创建新任务，保留原完成记录和文件。')) {
          await controller.redownload(task.id);
        }
      case 'delete':
        final file = await showDialog<bool>(
          context: context,
          builder: (context) => const DeleteDownloadDialog(),
        );
        if (file != null) await controller.deleteCompleted(task.id, file);
      case 'publication':
        await controller.retryPublication(task.id);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final completed = task.status == DownloadStatus.completed;
    final operation = ref.watch(downloadsControllerProvider);
    final busy =
        operation.busy.contains(task.id) ||
        (completed && operation.busy.contains('clearCompleted'));
    final pausable = [
      DownloadStatus.running,
      DownloadStatus.queued,
    ].contains(task.status);
    final resumable = [
      DownloadStatus.paused,
      DownloadStatus.waitingRecovery,
      DownloadStatus.failed,
    ].contains(task.status);
    final controller = ref.read(downloadsControllerProvider.notifier);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 12, right: 12),
                  child: Icon(Icons.insert_drive_file_outlined),
                ),
                Expanded(
                  child: InkWell(
                    onTap: () => action(context, ref, 'details'),
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 48),
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            task.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 2),
                          if (completed)
                            Text(
                              bytesLabel(task.downloadedBytes),
                              style: Theme.of(context).textTheme.bodySmall,
                            )
                          else
                            Text(
                              '${statusLabel(task.status)} · ${bytesLabel(task.downloadedBytes)} / '
                              '${task.totalBytes == null ? '总大小未知' : bytesLabel(task.totalBytes!)}'
                              '${task.progress != null ? ' · ${(task.progress! * 100).toStringAsFixed(0)}%' : ''}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (completed)
                  IconButton(
                    tooltip: '打开文件',
                    onPressed: busy ? null : () => controller.open(task.id),
                    icon: const Icon(Icons.open_in_new),
                  ),
                if (pausable || resumable)
                  IconButton(
                    tooltip: pausable ? '暂停' : '继续',
                    onPressed: busy
                        ? null
                        : () => pausable
                              ? controller.pause(task.id)
                              : controller.resume(task.id),
                    icon: Icon(pausable ? Icons.pause : Icons.play_arrow),
                  ),
                PopupMenuButton<String>(
                  tooltip: '更多操作',
                  enabled: !ref
                      .watch(downloadsControllerProvider)
                      .busy
                      .contains('cancel:${task.id}'),
                  onSelected: (value) => action(context, ref, value),
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'details', child: Text('查看详情')),
                    if (completed && !busy)
                      const PopupMenuItem(
                        value: 'redownload',
                        child: Text('重新下载'),
                      ),
                    if (!busy &&
                        (completed || task.status == DownloadStatus.deleting))
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('删除记录…'),
                      ),
                    if (!completed && task.status != DownloadStatus.deleting)
                      const PopupMenuItem(
                        value: 'cancel',
                        child: Text('取消下载…'),
                      ),
                    if (!busy && task.publishOperation != null && !completed)
                      const PopupMenuItem(
                        value: 'publication',
                        child: Text('核对并重试保存'),
                      ),
                  ],
                ),
              ],
            ),
            if (completed)
              Padding(
                padding: const EdgeInsets.only(left: 36, top: 2),
                child: Text(
                  completionTimeLabel(task.completedAt ?? task.updatedAt),
                  semanticsLabel:
                      '完成时间 ${completionTimeLabel(task.completedAt ?? task.updatedAt)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            if (!completed) ...[
              const SizedBox(height: 4),
              LinearProgressIndicator(
                value: task.progress?.clamp(0, 1),
                semanticsLabel: '下载进度',
                semanticsValue: task.progress == null
                    ? '百分比未知'
                    : '${(task.progress! * 100).toStringAsFixed(0)}%',
              ),
            ],
            if (task.lastError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  errorMessage(RepositoryException(task.lastError!)),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (task.publishOperation != null && !completed)
              TextButton(
                onPressed: busy
                    ? null
                    : () => controller.retryPublication(task.id),
                child: const Text('核对并重试保存'),
              ),
            if (busy)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('正在处理，请等待实际停止与保存结果…', semanticsLabel: '操作处理中'),
              ),
          ],
        ),
      ),
    );
  }
}

class ClearCompletedButton extends ConsumerWidget {
  const ClearCompletedButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(tasksProvider).asData?.value;
    final ids =
        tasks
            ?.where((task) => task.status == DownloadStatus.completed)
            .map((task) => task.id)
            .toList() ??
        <String>[];
    final busy = ref.watch(downloadsControllerProvider).busy.isNotEmpty;
    return IconButton(
      tooltip: '清空已下载',
      icon: const Icon(Icons.delete_sweep_outlined),
      onPressed: ids.isEmpty || busy
          ? null
          : () async {
              final deleteFiles = await showDialog<bool>(
                context: context,
                builder: (_) => const DeleteDownloadDialog(clearAll: true),
              );
              if (deleteFiles != null && context.mounted) {
                await ref
                    .read(downloadsControllerProvider.notifier)
                    .clearCompleted(ids, deleteFiles);
              }
            },
    );
  }
}

class DeleteDownloadDialog extends StatefulWidget {
  const DeleteDownloadDialog({super.key, this.clearAll = false});
  final bool clearAll;
  @override
  State<DeleteDownloadDialog> createState() => _DeleteDownloadDialogState();
}

class _DeleteDownloadDialogState extends State<DeleteDownloadDialog> {
  bool deleteFile = false;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.clearAll ? '清空已下载' : '删除下载记录'),
    scrollable: true,
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.clearAll ? '清空当前已完成列表中的所有记录，默认保留本地已下载文件。' : '默认只删除记录，保留已下载文件。',
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('同时删除本地已下载文件'),
          value: deleteFile,
          onChanged: (value) => setState(() => deleteFile = value!),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, deleteFile),
        child: Text(widget.clearAll ? '清空' : '删除'),
      ),
    ],
  );
}
