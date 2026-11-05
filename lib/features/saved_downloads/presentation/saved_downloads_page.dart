import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../downloads/presentation/providers.dart';
import '../../downloads/presentation/download_form.dart';
import '../../downloads/presentation/downloads_page.dart';

class SavedDownloadsPage extends ConsumerWidget {
  const SavedDownloadsPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(savedProvider)
      .when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => ErrorPanel(
          message: errorMessage(error),
          retry: () => ref.invalidate(savedProvider),
        ),
        data: (items) {
          if (items.isEmpty) {
            return EmptyPanel(
              label: '暂无缓存配置',
              action: '新增缓存',
              onPressed: () => showDownloadForm(context, saved: true),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            itemCount: items.length,
            itemBuilder: (context, index) {
              final saved = items[index];
              final busy = ref
                  .watch(downloadsControllerProvider)
                  .busy
                  .contains(saved.id);
              final controller = ref.read(downloadsControllerProvider.notifier);
              return Card(
                margin: const EdgeInsets.only(bottom: 16),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.bookmark_border),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              saved.fileName ?? saved.url,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          IconButton(
                            tooltip: '发起下载',
                            onPressed: busy
                                ? null
                                : () => controller.startSaved(saved.id),
                            icon: const Icon(Icons.download_outlined),
                          ),
                          PopupMenuButton<String>(
                            tooltip: '缓存操作',
                            enabled: !busy,
                            onSelected: (value) async {
                              if (value == 'edit') {
                                await showDownloadForm(
                                  context,
                                  saved: true,
                                  initial: saved,
                                );
                              }
                              if (value == 'delete' &&
                                  context.mounted &&
                                  await confirmAction(
                                    context,
                                    '删除缓存配置',
                                    '只删除配置，不影响下载任务或文件。',
                                  )) {
                                await controller.deleteSaved(saved.id);
                              }
                            },
                            itemBuilder: (_) => [
                              const PopupMenuItem(
                                value: 'edit',
                                child: Text('修改缓存'),
                              ),
                              const PopupMenuItem(
                                value: 'delete',
                                child: Text('删除缓存'),
                              ),
                            ],
                          ),
                        ],
                      ),
                      TextButton(
                        onPressed: () => showDialog<void>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('缓存详情'),
                            scrollable: true,
                            content: SelectableText(
                              '${saved.fileName ?? ''}\n${saved.url}\n保存目录：${saved.directory?.displayName ?? '默认目录'}',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('关闭'),
                              ),
                            ],
                          ),
                        ),
                        child: Text(
                          saved.url,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text('保存目录：${saved.directory?.displayName ?? '默认目录'}'),
                      if (busy) const Text('正在创建下载，请等待实际结果…'),
                    ],
                  ),
                ),
              );
            },
          );
        },
      );
}
