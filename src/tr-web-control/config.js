system.config = $.extend(system.config, {
	// Whether to enable automatic refresh
	autoReload: true,
	// Automatic refresh rate (ms)
	reloadStep: 5000,
	// The default num of entries for each page
	pageSize: 200,
	// Enable/disable pagination for torrentlist.datagrid
	pagination: true,
	// Options in torrentlist.datagrid PageList
	pageList: [10, 20, 30, 40, 50, 100, 150, 200, 250, 300, 5000],
	// The initial interface defaults to the selected node, the name can refer to the language package tree
	defaultSelectNode: "torrent-all",
	// Whether the torrent details are automatically expanded
	autoExpandAttribute: true,
	// default language
	defaultLang: "zh-CN",
	//show Folders
	foldersShow: false,
	// theme
	theme: "default",
	// 是否显示BT服务器
	showBTServers: false,
	// ipinfo.io token
	ipInfoToken: ''
});

// 主题样式
system.themes = [{
		value: 'default',
		text: '默认',
		group: '基础'
	},
	{
		value: 'gray',
		text: '灰色',
		group: '基础'
	},
	{
		value: 'metro',
		text: '简洁',
		group: '基础'
	},
	{
		value: 'material',
		text: '质感',
		group: '基础'
	},
	{
		value: 'bootstrap',
		text: '经典',
		group: '基础'
	},
	{
		value: 'black;logo-white.png',
		text: '黑色',
		group: '基础'
	},
	{
		value: 'metro-blue',
		text: '简洁蓝',
		group: '简洁'
	},
	{
		value: 'metro-gray',
		text: '简洁灰',
		group: '简洁'
	},
	{
		value: 'metro-green',
		text: '简洁绿',
		group: '简洁'
	},
	{
		value: 'metro-orange',
		text: '简洁橙',
		group: '简洁'
	},
	{
		value: 'metro-red',
		text: '简洁红',
		group: '简洁'
	},
	{
		value: 'ui-cupertino',
		text: '浅色',
		group: '更多主题'
	},
	{
		value: 'ui-dark-hive;logo-white.png',
		text: '深色',
		group: '更多主题'
	},
	{
		value: 'ui-pepper-grinder',
		text: '棕色',
		group: '更多主题'
	},
	{
		value: 'ui-sunny',
		text: '暖色',
		group: '更多主题'
	}
];
