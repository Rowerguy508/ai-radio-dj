(globalThis.TURBOPACK || (globalThis.TURBOPACK = [])).push([typeof document === "object" ? document.currentScript : undefined,
"[project]/clawd/ai-radio-dj/lib/store/radio.ts [app-client] (ecmascript)", ((__turbopack_context__) => {
"use strict";

__turbopack_context__.s([
    "useCurrentStation",
    ()=>useCurrentStation,
    "useCurrentTrack",
    ()=>useCurrentTrack,
    "useIsPlaying",
    ()=>useIsPlaying,
    "useRadioStore",
    ()=>useRadioStore,
    "useStations",
    ()=>useStations,
    "useVoices",
    ()=>useVoices
]);
var __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$zustand$2f$esm$2f$react$2e$mjs__$5b$app$2d$client$5d$__$28$ecmascript$29$__ = __turbopack_context__.i("[project]/clawd/ai-radio-dj/node_modules/zustand/esm/react.mjs [app-client] (ecmascript)");
var __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$zustand$2f$esm$2f$middleware$2e$mjs__$5b$app$2d$client$5d$__$28$ecmascript$29$__ = __turbopack_context__.i("[project]/clawd/ai-radio-dj/node_modules/zustand/esm/middleware.mjs [app-client] (ecmascript)");
var _s = __turbopack_context__.k.signature(), _s1 = __turbopack_context__.k.signature(), _s2 = __turbopack_context__.k.signature(), _s3 = __turbopack_context__.k.signature(), _s4 = __turbopack_context__.k.signature();
;
;
// Demo user ID for local-first mode
const DEMO_USER_ID = 'demo-user-raydo';
const useRadioStore = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$zustand$2f$esm$2f$react$2e$mjs__$5b$app$2d$client$5d$__$28$ecmascript$29$__["create"])()((0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$zustand$2f$esm$2f$middleware$2e$mjs__$5b$app$2d$client$5d$__$28$ecmascript$29$__["persist"])((set, get)=>({
        // Initial state
        isPlaying: false,
        currentTrack: null,
        currentStation: null,
        queue: [],
        volume: 0.7,
        crossfadeDuration: 5,
        stations: [],
        voices: [],
        showSettings: false,
        showVoiceSelector: false,
        commentaryEnabled: true,
        voices: [
            {
                id: '1',
                name: 'Alex',
                voiceId: '21m00Tcm4TlvDq8ikWAM',
                style: 0.5,
                language: 'English',
                personality: 'Professional & Warm'
            },
            {
                id: '2',
                name: 'Sarah',
                voiceId: 'AZnzlk1XvdvUeBnG7F4o',
                style: 0.6,
                language: 'English',
                personality: 'Energetic & Friendly'
            },
            {
                id: '3',
                name: 'James',
                voiceId: 'Fljq6R8y61NddGlE9krf',
                style: 0.4,
                language: 'English',
                personality: 'Deep & Authoritative'
            },
            {
                id: '4',
                name: 'Bella',
                voiceId: 'EXAVITQu4vr4xnSDxMaL',
                style: 0.7,
                language: 'English',
                personality: 'Soft & Smooth'
            },
            {
                id: '5',
                name: 'Daniel',
                voiceId: 'nPczCjz82KWdKScP46A1',
                style: 0.5,
                language: 'English',
                personality: 'Casual & Cool'
            }
        ],
        // Actions
        setCurrentTrack: (track)=>set({
                currentTrack: track
            }),
        setCurrentStation: (station)=>set({
                currentStation: station
            }),
        setIsPlaying: (playing)=>set({
                isPlaying: playing
            }),
        setVolume: (volume)=>set({
                volume
            }),
        setCrossfadeDuration: (duration)=>set({
                crossfadeDuration: duration
            }),
        setQueue: (queue)=>set({
                queue
            }),
        addToQueue: (track)=>set((state)=>({
                    queue: [
                        ...state.queue,
                        track
                    ]
                })),
        nextTrack: ()=>{
            const { queue } = get();
            if (queue.length > 0) {
                const [next, ...rest] = queue;
                set({
                    currentTrack: next,
                    queue: rest
                });
            }
        },
        toggleSettings: ()=>set((state)=>({
                    showSettings: !state.showSettings
                })),
        toggleVoiceSelector: ()=>set((state)=>({
                    showVoiceSelector: !state.showVoiceSelector
                })),
        toggleCommentary: ()=>set((state)=>({
                    commentaryEnabled: !state.commentaryEnabled
                })),
        // Local station management (no cloud sync needed for basic functionality)
        addStation: (station)=>{
            set((state)=>({
                    stations: [
                        ...state.stations,
                        station
                    ]
                }));
        },
        updateStation: (id, updates)=>{
            set((state)=>({
                    stations: state.stations.map((s)=>s.id === id ? {
                            ...s,
                            ...updates
                        } : s)
                }));
        },
        removeStation: (id)=>{
            set((state)=>({
                    stations: state.stations.filter((s)=>s.id !== id)
                }));
        },
        // Voice management
        addVoice: (voice)=>{
            set((state)=>({
                    voices: [
                        ...state.voices,
                        voice
                    ]
                }));
        },
        removeVoice: (id)=>{
            set((state)=>({
                    voices: state.voices.filter((v)=>v.id !== id)
                }));
        },
        // Cloud sync (optional - fails silently if Supabase not configured)
        syncToCloud: async (userId)=>{
            const { stations, voices } = get();
            try {
                await fetch('/api/stations/sync', {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json'
                    },
                    body: JSON.stringify({
                        userId,
                        stations,
                        voices
                    })
                });
            } catch (e) {
                console.warn('Cloud sync skipped (Supabase not configured)');
            }
        },
        loadFromCloud: async (userId)=>{
            try {
                const [stationsRes, voicesRes] = await Promise.all([
                    fetch(`/api/stations?userId=${userId}`),
                    fetch(`/api/voices?userId=${userId}`)
                ]);
                if (stationsRes.ok) {
                    const stationsData = await stationsRes.json();
                    const voicesData = await voicesRes.json();
                    set({
                        stations: stationsData.stations || [],
                        voices: voicesData.voices || []
                    });
                }
            } catch (e) {
                console.warn('Cloud load skipped (Supabase not configured), using local data');
            }
        }
    }), {
    name: 'raydo-radio-storage',
    partialize: (state)=>({
            stations: state.stations,
            voices: state.voices,
            volume: state.volume,
            crossfadeDuration: state.crossfadeDuration,
            commentaryEnabled: state.commentaryEnabled
        })
}));
const useCurrentTrack = ()=>{
    _s();
    return useRadioStore({
        "useCurrentTrack.useRadioStore": (state)=>state.currentTrack
    }["useCurrentTrack.useRadioStore"]);
};
_s(useCurrentTrack, "Qatgq0ZbWmBbo/BiOeesa/nJMME=", false, function() {
    return [
        useRadioStore
    ];
});
const useIsPlaying = ()=>{
    _s1();
    return useRadioStore({
        "useIsPlaying.useRadioStore": (state)=>state.isPlaying
    }["useIsPlaying.useRadioStore"]);
};
_s1(useIsPlaying, "Qatgq0ZbWmBbo/BiOeesa/nJMME=", false, function() {
    return [
        useRadioStore
    ];
});
const useCurrentStation = ()=>{
    _s2();
    return useRadioStore({
        "useCurrentStation.useRadioStore": (state)=>state.currentStation
    }["useCurrentStation.useRadioStore"]);
};
_s2(useCurrentStation, "Qatgq0ZbWmBbo/BiOeesa/nJMME=", false, function() {
    return [
        useRadioStore
    ];
});
const useStations = ()=>{
    _s3();
    return useRadioStore({
        "useStations.useRadioStore": (state)=>state.stations
    }["useStations.useRadioStore"]);
};
_s3(useStations, "Qatgq0ZbWmBbo/BiOeesa/nJMME=", false, function() {
    return [
        useRadioStore
    ];
});
const useVoices = ()=>{
    _s4();
    return useRadioStore({
        "useVoices.useRadioStore": (state)=>state.voices
    }["useVoices.useRadioStore"]);
};
_s4(useVoices, "Qatgq0ZbWmBbo/BiOeesa/nJMME=", false, function() {
    return [
        useRadioStore
    ];
});
if (typeof globalThis.$RefreshHelpers$ === 'object' && globalThis.$RefreshHelpers !== null) {
    __turbopack_context__.k.registerExports(__turbopack_context__.m, globalThis.$RefreshHelpers$);
}
}),
"[project]/clawd/ai-radio-dj/app/components/Settings.tsx [app-client] (ecmascript)", ((__turbopack_context__) => {
"use strict";

__turbopack_context__.s([
    "Settings",
    ()=>Settings
]);
var __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__ = __turbopack_context__.i("[project]/clawd/ai-radio-dj/node_modules/next/dist/compiled/react/jsx-dev-runtime.js [app-client] (ecmascript)");
var __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__ = __turbopack_context__.i("[project]/clawd/ai-radio-dj/node_modules/next/dist/compiled/react/index.js [app-client] (ecmascript)");
var __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$lucide$2d$react$2f$dist$2f$esm$2f$icons$2f$x$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__$3c$export__default__as__X$3e$__ = __turbopack_context__.i("[project]/clawd/ai-radio-dj/node_modules/lucide-react/dist/esm/icons/x.js [app-client] (ecmascript) <export default as X>");
var __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$lucide$2d$react$2f$dist$2f$esm$2f$icons$2f$mic$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__$3c$export__default__as__Mic$3e$__ = __turbopack_context__.i("[project]/clawd/ai-radio-dj/node_modules/lucide-react/dist/esm/icons/mic.js [app-client] (ecmascript) <export default as Mic>");
var __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$lucide$2d$react$2f$dist$2f$esm$2f$icons$2f$sliders$2d$vertical$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__$3c$export__default__as__Sliders$3e$__ = __turbopack_context__.i("[project]/clawd/ai-radio-dj/node_modules/lucide-react/dist/esm/icons/sliders-vertical.js [app-client] (ecmascript) <export default as Sliders>");
var __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$lucide$2d$react$2f$dist$2f$esm$2f$icons$2f$save$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__$3c$export__default__as__Save$3e$__ = __turbopack_context__.i("[project]/clawd/ai-radio-dj/node_modules/lucide-react/dist/esm/icons/save.js [app-client] (ecmascript) <export default as Save>");
var __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$lucide$2d$react$2f$dist$2f$esm$2f$icons$2f$user$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__$3c$export__default__as__User$3e$__ = __turbopack_context__.i("[project]/clawd/ai-radio-dj/node_modules/lucide-react/dist/esm/icons/user.js [app-client] (ecmascript) <export default as User>");
var __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$lucide$2d$react$2f$dist$2f$esm$2f$icons$2f$chevron$2d$down$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__$3c$export__default__as__ChevronDown$3e$__ = __turbopack_context__.i("[project]/clawd/ai-radio-dj/node_modules/lucide-react/dist/esm/icons/chevron-down.js [app-client] (ecmascript) <export default as ChevronDown>");
var __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$lib$2f$store$2f$radio$2e$ts__$5b$app$2d$client$5d$__$28$ecmascript$29$__ = __turbopack_context__.i("[project]/clawd/ai-radio-dj/lib/store/radio.ts [app-client] (ecmascript)");
;
var _s = __turbopack_context__.k.signature();
'use client';
;
;
;
function Settings() {
    _s();
    const { showSettings, toggleSettings, commentaryEnabled, toggleCommentary, crossfadeDuration, setCrossfadeDuration, currentStation, updateStation, voices } = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$lib$2f$store$2f$radio$2e$ts__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useRadioStore"])();
    const [localStation, setLocalStation] = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useState"])(currentStation);
    const [showVoiceDropdown, setShowVoiceDropdown] = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useState"])(false);
    if (!showSettings) return null;
    const handleSaveStation = ()=>{
        if (localStation && currentStation?.id === localStation.id) {
            updateStation(currentStation.id, localStation);
        }
    };
    const selectedVoice = voices.find((v)=>v.voiceId === localStation?.voiceId) || voices[0];
    return /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
        className: "fixed inset-0 bg-black/50 flex items-center justify-center z-50",
        children: /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
            className: "bg-zinc-900 rounded-xl w-full max-w-md p-6 m-4 max-h-[90vh] overflow-y-auto",
            children: [
                /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                    className: "flex items-center justify-between mb-6",
                    children: [
                        /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("h2", {
                            className: "text-xl font-bold text-white",
                            children: "Settings"
                        }, void 0, false, {
                            fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                            lineNumber: 38,
                            columnNumber: 11
                        }, this),
                        /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("button", {
                            onClick: toggleSettings,
                            className: "p-2 text-zinc-400 hover:text-white transition-colors",
                            children: /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])(__TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$lucide$2d$react$2f$dist$2f$esm$2f$icons$2f$x$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__$3c$export__default__as__X$3e$__["X"], {
                                size: 20
                            }, void 0, false, {
                                fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                lineNumber: 43,
                                columnNumber: 13
                            }, this)
                        }, void 0, false, {
                            fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                            lineNumber: 39,
                            columnNumber: 11
                        }, this)
                    ]
                }, void 0, true, {
                    fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                    lineNumber: 37,
                    columnNumber: 9
                }, this),
                /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                    className: "mb-6",
                    children: [
                        /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("label", {
                            className: "flex items-center gap-3 text-zinc-400 text-sm mb-2",
                            children: [
                                /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])(__TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$lucide$2d$react$2f$dist$2f$esm$2f$icons$2f$user$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__$3c$export__default__as__User$3e$__["User"], {
                                    size: 18
                                }, void 0, false, {
                                    fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                    lineNumber: 50,
                                    columnNumber: 13
                                }, this),
                                "AI Voice"
                            ]
                        }, void 0, true, {
                            fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                            lineNumber: 49,
                            columnNumber: 11
                        }, this),
                        /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                            className: "relative",
                            children: [
                                /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("button", {
                                    onClick: ()=>setShowVoiceDropdown(!showVoiceDropdown),
                                    className: "w-full flex items-center justify-between p-4 bg-zinc-800 rounded-lg hover:bg-zinc-700 transition-colors",
                                    children: [
                                        /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                                            className: "flex items-center gap-3",
                                            children: [
                                                /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                                                    className: "w-10 h-10 rounded-full bg-gradient-to-br from-purple-500 to-pink-500 flex items-center justify-center",
                                                    children: /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("span", {
                                                        className: "text-white font-medium",
                                                        children: selectedVoice?.name[0]
                                                    }, void 0, false, {
                                                        fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                                        lineNumber: 61,
                                                        columnNumber: 19
                                                    }, this)
                                                }, void 0, false, {
                                                    fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                                    lineNumber: 60,
                                                    columnNumber: 17
                                                }, this),
                                                /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                                                    className: "text-left",
                                                    children: [
                                                        /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("p", {
                                                            className: "text-white font-medium",
                                                            children: selectedVoice?.name
                                                        }, void 0, false, {
                                                            fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                                            lineNumber: 64,
                                                            columnNumber: 19
                                                        }, this),
                                                        /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("p", {
                                                            className: "text-zinc-500 text-xs",
                                                            children: selectedVoice?.personality
                                                        }, void 0, false, {
                                                            fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                                            lineNumber: 65,
                                                            columnNumber: 19
                                                        }, this)
                                                    ]
                                                }, void 0, true, {
                                                    fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                                    lineNumber: 63,
                                                    columnNumber: 17
                                                }, this)
                                            ]
                                        }, void 0, true, {
                                            fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                            lineNumber: 59,
                                            columnNumber: 15
                                        }, this),
                                        /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])(__TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$lucide$2d$react$2f$dist$2f$esm$2f$icons$2f$chevron$2d$down$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__$3c$export__default__as__ChevronDown$3e$__["ChevronDown"], {
                                            size: 18,
                                            className: `text-zinc-400 transition-transform ${showVoiceDropdown ? 'rotate-180' : ''}`
                                        }, void 0, false, {
                                            fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                            lineNumber: 68,
                                            columnNumber: 15
                                        }, this)
                                    ]
                                }, void 0, true, {
                                    fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                    lineNumber: 55,
                                    columnNumber: 13
                                }, this),
                                showVoiceDropdown && /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                                    className: "absolute top-full left-0 right-0 mt-2 bg-zinc-800 rounded-lg overflow-hidden z-10 shadow-xl border border-zinc-700",
                                    children: voices.map((voice)=>/*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("button", {
                                            onClick: ()=>{
                                                setLocalStation(localStation ? {
                                                    ...localStation,
                                                    voiceId: voice.voiceId,
                                                    voiceName: voice.name
                                                } : null);
                                                setShowVoiceDropdown(false);
                                            },
                                            className: `w-full flex items-center gap-3 p-3 hover:bg-zinc-700 transition-colors ${localStation?.voiceId === voice.voiceId ? 'bg-zinc-700' : ''}`,
                                            children: [
                                                /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                                                    className: "w-8 h-8 rounded-full bg-gradient-to-br from-purple-500 to-pink-500 flex items-center justify-center",
                                                    children: /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("span", {
                                                        className: "text-white text-sm font-medium",
                                                        children: voice.name[0]
                                                    }, void 0, false, {
                                                        fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                                        lineNumber: 85,
                                                        columnNumber: 23
                                                    }, this)
                                                }, void 0, false, {
                                                    fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                                    lineNumber: 84,
                                                    columnNumber: 21
                                                }, this),
                                                /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                                                    className: "text-left",
                                                    children: [
                                                        /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("p", {
                                                            className: "text-white text-sm",
                                                            children: voice.name
                                                        }, void 0, false, {
                                                            fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                                            lineNumber: 88,
                                                            columnNumber: 23
                                                        }, this),
                                                        /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("p", {
                                                            className: "text-zinc-500 text-xs",
                                                            children: voice.personality
                                                        }, void 0, false, {
                                                            fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                                            lineNumber: 89,
                                                            columnNumber: 23
                                                        }, this)
                                                    ]
                                                }, void 0, true, {
                                                    fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                                    lineNumber: 87,
                                                    columnNumber: 21
                                                }, this)
                                            ]
                                        }, voice.id, true, {
                                            fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                            lineNumber: 74,
                                            columnNumber: 19
                                        }, this))
                                }, void 0, false, {
                                    fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                    lineNumber: 72,
                                    columnNumber: 15
                                }, this)
                            ]
                        }, void 0, true, {
                            fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                            lineNumber: 54,
                            columnNumber: 11
                        }, this)
                    ]
                }, void 0, true, {
                    fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                    lineNumber: 48,
                    columnNumber: 9
                }, this),
                /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                    className: "mb-6",
                    children: /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("button", {
                        onClick: toggleCommentary,
                        className: "w-full flex items-center justify-between p-4 bg-zinc-800 rounded-lg",
                        children: [
                            /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                                className: "flex items-center gap-3",
                                children: [
                                    /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])(__TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$lucide$2d$react$2f$dist$2f$esm$2f$icons$2f$mic$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__$3c$export__default__as__Mic$3e$__["Mic"], {
                                        size: 20,
                                        className: commentaryEnabled ? 'text-white' : 'text-zinc-500'
                                    }, void 0, false, {
                                        fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                        lineNumber: 105,
                                        columnNumber: 15
                                    }, this),
                                    /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("span", {
                                        className: "text-white",
                                        children: "AI Commentary"
                                    }, void 0, false, {
                                        fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                        lineNumber: 106,
                                        columnNumber: 15
                                    }, this)
                                ]
                            }, void 0, true, {
                                fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                lineNumber: 104,
                                columnNumber: 13
                            }, this),
                            /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                                className: `w-12 h-6 rounded-full transition-colors ${commentaryEnabled ? 'bg-green-500' : 'bg-zinc-600'}`,
                                children: /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                                    className: `w-5 h-5 rounded-full bg-white mt-0.5 transition-transform ${commentaryEnabled ? 'translate-x-6' : 'translate-x-0.5'}`
                                }, void 0, false, {
                                    fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                    lineNumber: 111,
                                    columnNumber: 15
                                }, this)
                            }, void 0, false, {
                                fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                lineNumber: 108,
                                columnNumber: 13
                            }, this)
                        ]
                    }, void 0, true, {
                        fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                        lineNumber: 100,
                        columnNumber: 11
                    }, this)
                }, void 0, false, {
                    fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                    lineNumber: 99,
                    columnNumber: 9
                }, this),
                /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                    className: "mb-6",
                    children: [
                        /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                            className: "flex items-center gap-3 mb-3",
                            children: [
                                /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])(__TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$lucide$2d$react$2f$dist$2f$esm$2f$icons$2f$sliders$2d$vertical$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__$3c$export__default__as__Sliders$3e$__["Sliders"], {
                                    size: 20,
                                    className: "text-zinc-400"
                                }, void 0, false, {
                                    fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                    lineNumber: 121,
                                    columnNumber: 13
                                }, this),
                                /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("span", {
                                    className: "text-white",
                                    children: "Crossfade Duration"
                                }, void 0, false, {
                                    fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                    lineNumber: 122,
                                    columnNumber: 13
                                }, this)
                            ]
                        }, void 0, true, {
                            fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                            lineNumber: 120,
                            columnNumber: 11
                        }, this),
                        /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("input", {
                            type: "range",
                            min: 0,
                            max: 15,
                            step: 1,
                            value: crossfadeDuration,
                            onChange: (e)=>setCrossfadeDuration(parseFloat(e.target.value)),
                            className: "w-full h-2 bg-zinc-700 rounded-lg appearance-none cursor-pointer accent-white"
                        }, void 0, false, {
                            fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                            lineNumber: 124,
                            columnNumber: 11
                        }, this),
                        /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                            className: "flex justify-between text-xs text-zinc-500 mt-1",
                            children: [
                                /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("span", {
                                    children: "Instant"
                                }, void 0, false, {
                                    fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                    lineNumber: 134,
                                    columnNumber: 13
                                }, this),
                                /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("span", {
                                    children: [
                                        crossfadeDuration,
                                        "s"
                                    ]
                                }, void 0, true, {
                                    fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                    lineNumber: 135,
                                    columnNumber: 13
                                }, this),
                                /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("span", {
                                    children: "15s"
                                }, void 0, false, {
                                    fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                    lineNumber: 136,
                                    columnNumber: 13
                                }, this)
                            ]
                        }, void 0, true, {
                            fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                            lineNumber: 133,
                            columnNumber: 11
                        }, this)
                    ]
                }, void 0, true, {
                    fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                    lineNumber: 119,
                    columnNumber: 9
                }, this),
                currentStation && /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                    className: "mb-6",
                    children: [
                        /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("h3", {
                            className: "text-sm font-medium text-zinc-400 mb-3",
                            children: [
                                currentStation.name,
                                " Settings"
                            ]
                        }, void 0, true, {
                            fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                            lineNumber: 143,
                            columnNumber: 13
                        }, this),
                        /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                            className: "mb-4",
                            children: [
                                /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("label", {
                                    className: "block text-white text-sm mb-2",
                                    children: [
                                        "Energy Level: ",
                                        Math.round((localStation?.energyLevel || currentStation.energyLevel) * 100),
                                        "%"
                                    ]
                                }, void 0, true, {
                                    fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                    lineNumber: 149,
                                    columnNumber: 15
                                }, this),
                                /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("input", {
                                    type: "range",
                                    min: 0,
                                    max: 1,
                                    step: 0.05,
                                    value: localStation?.energyLevel ?? currentStation.energyLevel,
                                    onChange: (e)=>setLocalStation({
                                            ...localStation,
                                            energyLevel: parseFloat(e.target.value)
                                        }),
                                    className: "w-full h-2 bg-zinc-700 rounded-lg appearance-none cursor-pointer accent-white"
                                }, void 0, false, {
                                    fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                    lineNumber: 152,
                                    columnNumber: 15
                                }, this),
                                /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                                    className: "flex justify-between text-xs text-zinc-500 mt-1",
                                    children: [
                                        /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("span", {
                                            children: "Chill"
                                        }, void 0, false, {
                                            fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                            lineNumber: 165,
                                            columnNumber: 17
                                        }, this),
                                        /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("span", {
                                            children: "Balanced"
                                        }, void 0, false, {
                                            fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                            lineNumber: 166,
                                            columnNumber: 17
                                        }, this),
                                        /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("span", {
                                            children: "Hype"
                                        }, void 0, false, {
                                            fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                            lineNumber: 167,
                                            columnNumber: 17
                                        }, this)
                                    ]
                                }, void 0, true, {
                                    fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                    lineNumber: 164,
                                    columnNumber: 15
                                }, this)
                            ]
                        }, void 0, true, {
                            fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                            lineNumber: 148,
                            columnNumber: 13
                        }, this),
                        /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                            className: "mb-4",
                            children: [
                                /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("label", {
                                    className: "block text-white text-sm mb-2",
                                    children: "Commentary Style"
                                }, void 0, false, {
                                    fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                    lineNumber: 173,
                                    columnNumber: 15
                                }, this),
                                /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                                    className: "grid grid-cols-3 gap-2",
                                    children: [
                                        'chill',
                                        'balanced',
                                        'hype'
                                    ].map((style)=>/*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("button", {
                                            onClick: ()=>setLocalStation({
                                                    ...localStation,
                                                    style
                                                }),
                                            className: `py-2 px-4 rounded-lg text-sm transition-colors ${(localStation?.style ?? currentStation.style) === style ? 'bg-white text-black' : 'bg-zinc-800 text-zinc-400 hover:bg-zinc-700'}`,
                                            children: style.charAt(0).toUpperCase() + style.slice(1)
                                        }, style, false, {
                                            fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                            lineNumber: 176,
                                            columnNumber: 19
                                        }, this))
                                }, void 0, false, {
                                    fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                    lineNumber: 174,
                                    columnNumber: 15
                                }, this)
                            ]
                        }, void 0, true, {
                            fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                            lineNumber: 172,
                            columnNumber: 13
                        }, this),
                        /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                            className: "space-y-2",
                            children: [
                                /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("label", {
                                    className: "flex items-center justify-between p-3 bg-zinc-800 rounded-lg cursor-pointer",
                                    children: [
                                        /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("span", {
                                            className: "text-white text-sm",
                                            children: "Include Messages"
                                        }, void 0, false, {
                                            fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                            lineNumber: 197,
                                            columnNumber: 17
                                        }, this),
                                        /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("input", {
                                            type: "checkbox",
                                            checked: localStation?.includeMessages ?? currentStation.includeMessages,
                                            onChange: (e)=>setLocalStation({
                                                    ...localStation,
                                                    includeMessages: e.target.checked
                                                }),
                                            className: "w-5 h-5 rounded border-zinc-600 bg-zinc-700 text-white focus:ring-white"
                                        }, void 0, false, {
                                            fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                            lineNumber: 198,
                                            columnNumber: 17
                                        }, this)
                                    ]
                                }, void 0, true, {
                                    fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                    lineNumber: 196,
                                    columnNumber: 15
                                }, this),
                                /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("label", {
                                    className: "flex items-center justify-between p-3 bg-zinc-800 rounded-lg cursor-pointer",
                                    children: [
                                        /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("span", {
                                            className: "text-white text-sm",
                                            children: "Include Calendar"
                                        }, void 0, false, {
                                            fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                            lineNumber: 210,
                                            columnNumber: 17
                                        }, this),
                                        /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("input", {
                                            type: "checkbox",
                                            checked: localStation?.includeCalendar ?? currentStation.includeCalendar,
                                            onChange: (e)=>setLocalStation({
                                                    ...localStation,
                                                    includeCalendar: e.target.checked
                                                }),
                                            className: "w-5 h-5 rounded border-zinc-600 bg-zinc-700 text-white focus:ring-white"
                                        }, void 0, false, {
                                            fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                            lineNumber: 211,
                                            columnNumber: 17
                                        }, this)
                                    ]
                                }, void 0, true, {
                                    fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                    lineNumber: 209,
                                    columnNumber: 15
                                }, this),
                                /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("label", {
                                    className: "flex items-center justify-between p-3 bg-zinc-800 rounded-lg cursor-pointer",
                                    children: [
                                        /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("span", {
                                            className: "text-white text-sm",
                                            children: "Include News"
                                        }, void 0, false, {
                                            fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                            lineNumber: 223,
                                            columnNumber: 17
                                        }, this),
                                        /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("input", {
                                            type: "checkbox",
                                            checked: localStation?.includeNews ?? currentStation.includeNews,
                                            onChange: (e)=>setLocalStation({
                                                    ...localStation,
                                                    includeNews: e.target.checked
                                                }),
                                            className: "w-5 h-5 rounded border-zinc-600 bg-zinc-700 text-white focus:ring-white"
                                        }, void 0, false, {
                                            fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                            lineNumber: 224,
                                            columnNumber: 17
                                        }, this)
                                    ]
                                }, void 0, true, {
                                    fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                                    lineNumber: 222,
                                    columnNumber: 15
                                }, this)
                            ]
                        }, void 0, true, {
                            fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                            lineNumber: 195,
                            columnNumber: 13
                        }, this)
                    ]
                }, void 0, true, {
                    fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                    lineNumber: 142,
                    columnNumber: 11
                }, this),
                /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("button", {
                    onClick: handleSaveStation,
                    className: "w-full flex items-center justify-center gap-2 py-3 bg-white text-black rounded-lg font-medium hover:bg-zinc-200 transition-colors",
                    children: [
                        /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])(__TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$lucide$2d$react$2f$dist$2f$esm$2f$icons$2f$save$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__$3c$export__default__as__Save$3e$__["Save"], {
                            size: 18
                        }, void 0, false, {
                            fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                            lineNumber: 243,
                            columnNumber: 11
                        }, this),
                        "Save Settings"
                    ]
                }, void 0, true, {
                    fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
                    lineNumber: 239,
                    columnNumber: 9
                }, this)
            ]
        }, void 0, true, {
            fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
            lineNumber: 35,
            columnNumber: 7
        }, this)
    }, void 0, false, {
        fileName: "[project]/clawd/ai-radio-dj/app/components/Settings.tsx",
        lineNumber: 34,
        columnNumber: 5
    }, this);
}
_s(Settings, "to3ILL4e4mcLbbufwDitCa+hCCw=", false, function() {
    return [
        __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$lib$2f$store$2f$radio$2e$ts__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useRadioStore"]
    ];
});
_c = Settings;
var _c;
__turbopack_context__.k.register(_c, "Settings");
if (typeof globalThis.$RefreshHelpers$ === 'object' && globalThis.$RefreshHelpers !== null) {
    __turbopack_context__.k.registerExports(__turbopack_context__.m, globalThis.$RefreshHelpers$);
}
}),
"[project]/clawd/ai-radio-dj/lib/apple-music/player.tsx [app-client] (ecmascript)", ((__turbopack_context__) => {
"use strict";

__turbopack_context__.s([
    "AppleMusicProvider",
    ()=>AppleMusicProvider,
    "useAppleMusic",
    ()=>useAppleMusic
]);
var __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$build$2f$polyfills$2f$process$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__ = /*#__PURE__*/ __turbopack_context__.i("[project]/clawd/ai-radio-dj/node_modules/next/dist/build/polyfills/process.js [app-client] (ecmascript)");
var __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__ = __turbopack_context__.i("[project]/clawd/ai-radio-dj/node_modules/next/dist/compiled/react/jsx-dev-runtime.js [app-client] (ecmascript)");
var __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__ = __turbopack_context__.i("[project]/clawd/ai-radio-dj/node_modules/next/dist/compiled/react/index.js [app-client] (ecmascript)");
var __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$lib$2f$store$2f$radio$2e$ts__$5b$app$2d$client$5d$__$28$ecmascript$29$__ = __turbopack_context__.i("[project]/clawd/ai-radio-dj/lib/store/radio.ts [app-client] (ecmascript)");
;
var _s = __turbopack_context__.k.signature(), _s1 = __turbopack_context__.k.signature();
'use client';
;
;
const AppleMusicContext = /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["createContext"])(null);
function AppleMusicProvider({ children }) {
    _s();
    const { setQueue, setCurrentTrack, setIsPlaying } = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$lib$2f$store$2f$radio$2e$ts__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useRadioStore"])();
    const [user, setUser] = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useState"])(null);
    const [isLoading, setIsLoading] = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useState"])(false);
    const [error, setError] = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useState"])(null);
    const [playlists, setPlaylists] = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useState"])([]);
    const [mk, setMk] = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useState"])(null);
    const [skipCount, setSkipCount] = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useState"])(0);
    const [lastSongId, setLastSongId] = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useState"])(null);
    const [commentaryEnabled, setCommentaryEnabled] = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useState"])(true);
    const commentaryAudioRef = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useRef"])(null);
    const isPlayingRef = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useRef"])(false);
    // Skip feedback loop - store skipped song IDs
    const skippedSongsRef = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useRef"])(new Set());
    // Load skipped songs from localStorage
    (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useEffect"])({
        "AppleMusicProvider.useEffect": ()=>{
            if ("TURBOPACK compile-time truthy", 1) {
                try {
                    const saved = localStorage.getItem('raydo_skipped_songs');
                    if (saved) {
                        const parsed = JSON.parse(saved);
                        skippedSongsRef.current = new Set(parsed);
                    }
                } catch (e) {
                    console.log('Failed to load skip history');
                }
            }
        }
    }["AppleMusicProvider.useEffect"], []);
    // Save skipped songs to localStorage
    const saveSkipHistory = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useCallback"])({
        "AppleMusicProvider.useCallback[saveSkipHistory]": ()=>{
            if ("TURBOPACK compile-time truthy", 1) {
                try {
                    localStorage.setItem('raydo_skipped_songs', JSON.stringify(Array.from(skippedSongsRef.current)));
                } catch (e) {
                    console.log('Failed to save skip history');
                }
            }
        }
    }["AppleMusicProvider.useCallback[saveSkipHistory]"], []);
    // Initialize MusicKit
    (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useEffect"])({
        "AppleMusicProvider.useEffect": ()=>{
            const token = ("TURBOPACK compile-time value", "eyJhbGciOiJFUzI1NiIsImtpZCI6Ik5KVTdHMjRBR00iLCJ0eXAiOiJKV1QifQ.eyJpc3MiOiJTODVBUEI3M1lWIiwiaWF0IjoxNzY5NjIxNzEyLCJleHAiOjE3ODUxNzM3MTJ9.MEYCIQDjoDYLTuPURrgC_ytnQEDQLzoN_sc4iO9NxVPVZ67jTAIhAO2sjj7AWqpZyCSC5tDd_TH2S7TZhHRbuig2Z1QEvsKp");
            if (!token || token.startsWith('your_') || token.length < 100) {
                console.log('No valid Apple Music token');
                return;
            }
            if (!window.MusicKit) {
                const script = document.createElement('script');
                script.src = 'https://js-cdn.music.apple.com/musickit/v3/musickit.js';
                script.async = true;
                script.onload = ({
                    "AppleMusicProvider.useEffect": async ()=>{
                        try {
                            const MusicKit = window.MusicKit;
                            await MusicKit.configure({
                                developerToken: token,
                                app: {
                                    name: 'RAY.DO',
                                    build: '1.0.0'
                                }
                            });
                            const instance = MusicKit.getInstance();
                            setMk(instance);
                            // Handle play/pause state changes
                            instance.addEventListener('playbackStateDidChange', {
                                "AppleMusicProvider.useEffect": (state)=>{
                                    console.log('MusicKit playback state:', state);
                                    isPlayingRef.current = state === 'playing';
                                    setIsPlaying(state === 'playing');
                                    // Auto-skip to next song if current ended
                                    if (state === 'ended' || state === 'completed') {
                                        handleAutoSkip();
                                    }
                                }
                            }["AppleMusicProvider.useEffect"]);
                            // Track skips from Player component
                            if ("TURBOPACK compile-time truthy", 1) {
                                window.addEventListener('raydo:skip', {
                                    "AppleMusicProvider.useEffect": ()=>{
                                        setSkipCount({
                                            "AppleMusicProvider.useEffect": (prev)=>{
                                                const newCount = prev + 1;
                                                console.log('Skip tracked, count:', newCount);
                                                // Track which song was skipped
                                                if (instance.nowPlayingItem?.id) {
                                                    skippedSongsRef.current.add(instance.nowPlayingItem.id);
                                                    saveSkipHistory();
                                                    console.log('Skipped song ID:', instance.nowPlayingItem.id);
                                                }
                                                return newCount;
                                            }
                                        }["AppleMusicProvider.useEffect"]);
                                    }
                                }["AppleMusicProvider.useEffect"]);
                            }
                            // Listen for song changes
                            instance.addEventListener('nowPlayingItemDidChange', {
                                "AppleMusicProvider.useEffect": async (item)=>{
                                    if (item) {
                                        console.log('Song changed:', item.title, 'by', item.artistName);
                                        setCurrentTrack({
                                            id: item.id,
                                            title: item.title,
                                            artistName: item.artistName,
                                            artworkUrl: item.artworkURL,
                                            duration: item.duration
                                        });
                                        // Maybe play commentary after song starts (50% chance)
                                        if (commentaryEnabled && Math.random() > 0.5) {
                                            await playCommentary();
                                        }
                                    }
                                }
                            }["AppleMusicProvider.useEffect"]);
                            console.log('MusicKit initialized');
                        } catch (e) {
                            console.log('MusicKit configure failed:', e);
                        }
                    }
                })["AppleMusicProvider.useEffect"];
                document.head.appendChild(script);
            } else {
                const MusicKit = window.MusicKit;
                MusicKit.configure({
                    developerToken: token,
                    app: {
                        name: 'RAY.DO',
                        build: '1.0.0'
                    }
                }).then({
                    "AppleMusicProvider.useEffect": ()=>{
                        const instance = MusicKit.getInstance();
                        setMk(instance);
                        console.log('MusicKit ready (cached)');
                    }
                }["AppleMusicProvider.useEffect"]);
            }
            return ({
                "AppleMusicProvider.useEffect": ()=>{
                    if (commentaryAudioRef.current) {
                        commentaryAudioRef.current.pause();
                    }
                }
            })["AppleMusicProvider.useEffect"];
        }
    }["AppleMusicProvider.useEffect"], []);
    // Auto-skip when song ends
    const handleAutoSkip = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useCallback"])({
        "AppleMusicProvider.useCallback[handleAutoSkip]": ()=>{
            const music = mk || window.MusicKit && window.MusicKit.getInstance();
            if (music && typeof music.skipToNext === 'function') {
                console.log('Auto-skipping to next song...');
                music.skipToNext();
            }
        }
    }["AppleMusicProvider.useCallback[handleAutoSkip]"], [
        mk
    ]);
    // Play AI commentary
    const playCommentary = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useCallback"])({
        "AppleMusicProvider.useCallback[playCommentary]": async ()=>{
            const elevenLabsKey = __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$build$2f$polyfills$2f$process$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["default"].env.ELEVENLABS_API_KEY;
            if (!elevenLabsKey || elevenLabsKey.startsWith('your_')) return;
            // Don't interrupt music playback - commentary only plays between songs
            if (isPlayingRef.current && !commentaryAudioRef.current?.paused) return;
            // Get voice from station or use default
            const voiceId = currentStation?.voiceId || '21m00Tcm4TlvDq8ikWAM'; // Default to Alex
            const hour = new Date().getHours();
            let timeGreeting = '';
            if (hour >= 5 && hour < 12) timeGreeting = 'Good morning! ';
            else if (hour >= 12 && hour < 17) timeGreeting = 'Good afternoon! ';
            else if (hour >= 17 && hour < 21) timeGreeting = 'Good evening! ';
            else timeGreeting = 'Late night vibes! ';
            const comments = [
                timeGreeting + "Here's another track for you.",
                timeGreeting + "This one fits the vibe perfectly.",
                timeGreeting + "Keep the good vibes going.",
                timeGreeting + "Another favorite coming up.",
                "You're listening to RAY.DO.",
                "More great music coming up.",
                "This track is a perfect match for your mood."
            ];
            const text = comments[Math.floor(Math.random() * comments.length)];
            try {
                console.log('Playing AI commentary:', text, 'with voice:', voiceId);
                const ttsResponse = await fetch(`https://api.elevenlabs.io/v1/text-to-speech/${voiceId}`, {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json',
                        'xi-api-key': elevenLabsKey
                    },
                    body: JSON.stringify({
                        text,
                        model_id: 'eleven_monolingual_v1',
                        voice_settings: {
                            stability: 0.5,
                            similarity_boost: 0.75
                        }
                    })
                });
                if (ttsResponse.ok) {
                    const audioBlob = await ttsResponse.blob();
                    const audioUrl = URL.createObjectURL(audioBlob);
                    if (commentaryAudioRef.current) {
                        commentaryAudioRef.current.pause();
                    }
                    commentaryAudioRef.current = new Audio(audioUrl);
                    await commentaryAudioRef.current.play();
                    console.log('AI commentary playing');
                }
            } catch (e) {
                console.log('Commentary failed:', e);
            }
        }
    }["AppleMusicProvider.useCallback[playCommentary]"], [
        commentaryEnabled
    ]);
    // Play function
    const play = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useCallback"])({
        "AppleMusicProvider.useCallback[play]": async ()=>{
            const music = mk || window.MusicKit && window.MusicKit.getInstance();
            if (music) {
                try {
                    await music.play();
                    isPlayingRef.current = true;
                    setIsPlaying(true);
                    console.log('MusicKit play');
                } catch (e) {
                    console.log('Play failed:', e);
                }
            }
        }
    }["AppleMusicProvider.useCallback[play]"], [
        mk
    ]);
    // Pause function
    const pause = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useCallback"])({
        "AppleMusicProvider.useCallback[pause]": ()=>{
            const music = mk || window.MusicKit && window.MusicKit.getInstance();
            if (music) {
                try {
                    music.pause();
                    isPlayingRef.current = false;
                    setIsPlaying(false);
                    console.log('MusicKit pause');
                } catch (e) {
                    console.log('Pause failed:', e);
                }
            }
        }
    }["AppleMusicProvider.useCallback[pause]"], [
        mk
    ]);
    // Skip function
    const skip = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useCallback"])({
        "AppleMusicProvider.useCallback[skip]": ()=>{
            // Dispatch skip event
            if ("TURBOPACK compile-time truthy", 1) {
                window.dispatchEvent(new CustomEvent('raydo:skip'));
            }
            const music = mk || window.MusicKit && window.MusicKit.getInstance();
            if (music) {
                if (typeof music.skipToNext === 'function') {
                    music.skipToNext();
                } else if (music.player && typeof music.player.skipToNextItem === 'function') {
                    music.player.skipToNextItem();
                }
                console.log('MusicKit skip');
            }
        }
    }["AppleMusicProvider.useCallback[skip]"], [
        mk
    ]);
    const connectAppleMusic = async ()=>{
        if (!mk) {
            setError('Initializing...');
            return;
        }
        setIsLoading(true);
        try {
            await mk.authorize();
            setUser({
                name: 'Apple Music User',
                email: '',
                id: ''
            });
        } catch (e) {
            setError('Auth failed: ' + e.message);
        } finally{
            setIsLoading(false);
        }
    };
    const disconnect = ()=>{
        if (mk) mk.unauthorize();
        setUser(null);
        setPlaylists([]);
        setSkipCount(0);
    };
    // Weighted shuffle - popular tracks more likely to play, skipped songs deprioritized
    const weightedShuffle = (array)=>{
        const arr = [
            ...array
        ];
        // Calculate weights based on track duration (shorter = slightly more weight for variety)
        // and recency if release date available
        const weights = arr.map((track)=>{
            let weight = 1;
            // Penalize skipped songs heavily
            if (skippedSongsRef.current.has(track.id)) {
                weight *= 0.1; // 90% reduction for skipped songs
            }
            // Slight boost for shorter tracks (3-4 min sweet spot)
            const duration = track.attributes?.durationInMillis || 180000;
            const minutes = duration / 60000;
            if (minutes >= 3 && minutes <= 4) weight *= 1.2;
            else if (minutes < 3) weight *= 1.1;
            else if (minutes > 5) weight *= 0.8;
            // Add randomness
            weight *= 0.6 + Math.random() * 0.8;
            return {
                item: track,
                weight,
                originalIndex: arr.indexOf(track)
            };
        });
        // Sort by weight (descending) then shuffle
        weights.sort((a, b)=>b.weight - a.weight);
        // Fisher-Yates shuffle with weight consideration
        for(let i = weights.length - 1; i > 0; i--){
            const j = Math.floor(Math.random() * (i + 1));
            [weights[i], weights[j]] = [
                weights[j],
                weights[i]
            ];
        }
        return weights.map((w)=>w.item);
    };
    // Simple shuffle for fallback
    const simpleShuffle = (array)=>{
        const arr = [
            ...array
        ];
        for(let i = arr.length - 1; i > 0; i--){
            const j = Math.floor(Math.random() * (i + 1));
            [arr[i], arr[j]] = [
                arr[j],
                arr[i]
            ];
        }
        return arr;
    };
    const createRadioStation = async (mood)=>{
        const music = mk || window.MusicKit && window.MusicKit.getInstance();
        if (!music) {
            setError('Apple Music not ready');
            return;
        }
        // Ensure authorized
        if (!music.isAuthorized) {
            try {
                await music.authorize();
            } catch (e) {
                setError('Auth failed: ' + e.message);
                return;
            }
        }
        if (!music.musicUserToken) {
            console.log('No musicUserToken');
            return;
        }
        setIsLoading(true);
        setError(null);
        setSkipCount(0);
        const genres = {
            chill: [
                'chill',
                'lo-fi',
                'ambient',
                'acoustic'
            ],
            hype: [
                'hip-hop',
                'electronic',
                'dance',
                'trap'
            ],
            balanced: [
                'pop',
                'rock',
                'indie',
                'alternative'
            ]
        };
        const genreList = genres[mood];
        console.log('Fetching songs from genres:', genreList);
        const token = ("TURBOPACK compile-time value", "eyJhbGciOiJFUzI1NiIsImtpZCI6Ik5KVTdHMjRBR00iLCJ0eXAiOiJKV1QifQ.eyJpc3MiOiJTODVBUEI3M1lWIiwiaWF0IjoxNzY5NjIxNzEyLCJleHAiOjE3ODUxNzM3MTJ9.MEYCIQDjoDYLTuPURrgC_ytnQEDQLzoN_sc4iO9NxVPVZ67jTAIhAO2sjj7AWqpZyCSC5tDd_TH2S7TZhHRbuig2Z1QEvsKp");
        const elevenLabsKey = __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$build$2f$polyfills$2f$process$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["default"].env.ELEVENLABS_API_KEY;
        try {
            let allTracks = [];
            // Fetch from each genre
            for (const genre of genreList){
                const response = await fetch(`https://api.music.apple.com/v1/catalog/us/search?term=${encodeURIComponent(genre)}&types=songs&limit=20`, {
                    headers: {
                        'Authorization': `Bearer ${token}`,
                        'Music-User-Token': music.musicUserToken
                    }
                });
                if (response.ok) {
                    const data = await response.json();
                    const tracks = data?.results?.songs?.data || [];
                    allTracks = [
                        ...allTracks,
                        ...tracks
                    ];
                }
            }
            // Remove duplicates
            const uniqueTracks = allTracks.filter((track, index, self)=>index === self.findIndex((t)=>t.id === track.id));
            // Shuffle
            const shuffledTracks = weightedShuffle(uniqueTracks);
            console.log(`Found ${shuffledTracks.length} unique tracks`);
            if (shuffledTracks.length > 0) {
                const songIds = shuffledTracks.map((t)=>t.id);
                // Update UI
                const uiTracks = shuffledTracks.map((t)=>({
                        id: t.id,
                        title: t.attributes.name,
                        artistName: t.attributes.artistName,
                        artworkUrl: t.attributes.artwork?.url?.replace('{w}', '200').replace('{h}', '200'),
                        duration: Math.floor(t.attributes.durationInMillis / 1000),
                        previewUrl: t.attributes.previewUrl
                    }));
                setQueue(uiTracks);
                setCurrentTrack(uiTracks[0]);
                // Play opening commentary
                if (elevenLabsKey && !elevenLabsKey.startsWith('your_')) {
                    const vibeDescriptions = {
                        chill: "Welcome to your chill zone. Smooth vibes, laid-back beats, and ambient sounds to help you unwind. Here's your personalized mix.",
                        hype: "Turn it up! High-energy tracks, bangers, and beats that'll keep you moving. Your hype mix is ready.",
                        balanced: "The perfect mix of pop hits, rock anthems, and indie gems. Something for everyone, never boring. Enjoy!"
                    };
                    try {
                        console.log('Playing intro commentary...');
                        const ttsResponse = await fetch('https://api.elevenlabs.io/v1/text-to-speech/21m00Tcm4TlvDq8ikWAM', {
                            method: 'POST',
                            headers: {
                                'Content-Type': 'application/json',
                                'xi-api-key': elevenLabsKey
                            },
                            body: JSON.stringify({
                                text: vibeDescriptions[mood],
                                model_id: 'eleven_monolingual_v1',
                                voice_settings: {
                                    stability: 0.5,
                                    similarity_boost: 0.75
                                }
                            })
                        });
                        if (ttsResponse.ok) {
                            const audioBlob = await ttsResponse.blob();
                            const audioUrl = URL.createObjectURL(audioBlob);
                            // Play intro
                            commentaryAudioRef.current = new Audio(audioUrl);
                            await commentaryAudioRef.current.play();
                            // When intro ends, start music
                            commentaryAudioRef.current.onended = async ()=>{
                                console.log('Intro ended, starting music...');
                                await music.setQueue({
                                    songs: songIds
                                });
                                await music.play();
                                isPlayingRef.current = true;
                                setIsPlaying(true);
                            };
                            setIsLoading(false);
                            return;
                        }
                    } catch (ttsError) {
                        console.log('ElevenLabs TTS failed:', ttsError);
                    }
                }
                // No commentary - just play
                await music.setQueue({
                    songs: songIds
                });
                await music.play();
                isPlayingRef.current = true;
                setIsPlaying(true);
                console.log('Playing shuffled queue');
                setIsLoading(false);
                return;
            }
            console.log('No tracks found');
        } catch (e) {
            console.error('Apple Music error:', e);
        }
        // Fallback
        setIsLoading(false);
    };
    return /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])(AppleMusicContext.Provider, {
        value: {
            user,
            isAuthenticated: !!user,
            isLoading,
            error,
            playlists,
            connectAppleMusic,
            disconnect,
            createRadioStation,
            play,
            pause,
            skip
        },
        children: children
    }, void 0, false, {
        fileName: "[project]/clawd/ai-radio-dj/lib/apple-music/player.tsx",
        lineNumber: 522,
        columnNumber: 5
    }, this);
}
_s(AppleMusicProvider, "P9esswo2s5RzcE21d4+nQbPXvyI=", false, function() {
    return [
        __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$lib$2f$store$2f$radio$2e$ts__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useRadioStore"]
    ];
});
_c = AppleMusicProvider;
function useAppleMusic() {
    _s1();
    const ctx = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useContext"])(AppleMusicContext);
    if (!ctx) throw new Error('useAppleMusic requires provider');
    return ctx;
}
_s1(useAppleMusic, "/dMy7t63NXD4eYACoT93CePwGrg=");
var _c;
__turbopack_context__.k.register(_c, "AppleMusicProvider");
if (typeof globalThis.$RefreshHelpers$ === 'object' && globalThis.$RefreshHelpers !== null) {
    __turbopack_context__.k.registerExports(__turbopack_context__.m, globalThis.$RefreshHelpers$);
}
}),
"[project]/clawd/ai-radio-dj/app/components/Player.tsx [app-client] (ecmascript)", ((__turbopack_context__) => {
"use strict";

__turbopack_context__.s([
    "Player",
    ()=>Player
]);
var __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__ = __turbopack_context__.i("[project]/clawd/ai-radio-dj/node_modules/next/dist/compiled/react/jsx-dev-runtime.js [app-client] (ecmascript)");
var __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__ = __turbopack_context__.i("[project]/clawd/ai-radio-dj/node_modules/next/dist/compiled/react/index.js [app-client] (ecmascript)");
var __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$lucide$2d$react$2f$dist$2f$esm$2f$icons$2f$play$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__$3c$export__default__as__Play$3e$__ = __turbopack_context__.i("[project]/clawd/ai-radio-dj/node_modules/lucide-react/dist/esm/icons/play.js [app-client] (ecmascript) <export default as Play>");
var __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$lucide$2d$react$2f$dist$2f$esm$2f$icons$2f$pause$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__$3c$export__default__as__Pause$3e$__ = __turbopack_context__.i("[project]/clawd/ai-radio-dj/node_modules/lucide-react/dist/esm/icons/pause.js [app-client] (ecmascript) <export default as Pause>");
var __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$lucide$2d$react$2f$dist$2f$esm$2f$icons$2f$skip$2d$forward$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__$3c$export__default__as__SkipForward$3e$__ = __turbopack_context__.i("[project]/clawd/ai-radio-dj/node_modules/lucide-react/dist/esm/icons/skip-forward.js [app-client] (ecmascript) <export default as SkipForward>");
var __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$lucide$2d$react$2f$dist$2f$esm$2f$icons$2f$skip$2d$back$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__$3c$export__default__as__SkipBack$3e$__ = __turbopack_context__.i("[project]/clawd/ai-radio-dj/node_modules/lucide-react/dist/esm/icons/skip-back.js [app-client] (ecmascript) <export default as SkipBack>");
var __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$lucide$2d$react$2f$dist$2f$esm$2f$icons$2f$volume$2d$2$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__$3c$export__default__as__Volume2$3e$__ = __turbopack_context__.i("[project]/clawd/ai-radio-dj/node_modules/lucide-react/dist/esm/icons/volume-2.js [app-client] (ecmascript) <export default as Volume2>");
var __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$lucide$2d$react$2f$dist$2f$esm$2f$icons$2f$volume$2d$x$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__$3c$export__default__as__VolumeX$3e$__ = __turbopack_context__.i("[project]/clawd/ai-radio-dj/node_modules/lucide-react/dist/esm/icons/volume-x.js [app-client] (ecmascript) <export default as VolumeX>");
var __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$lib$2f$store$2f$radio$2e$ts__$5b$app$2d$client$5d$__$28$ecmascript$29$__ = __turbopack_context__.i("[project]/clawd/ai-radio-dj/lib/store/radio.ts [app-client] (ecmascript)");
var __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$lib$2f$apple$2d$music$2f$player$2e$tsx__$5b$app$2d$client$5d$__$28$ecmascript$29$__ = __turbopack_context__.i("[project]/clawd/ai-radio-dj/lib/apple-music/player.tsx [app-client] (ecmascript)");
;
var _s = __turbopack_context__.k.signature();
'use client';
;
;
;
;
function Player() {
    _s();
    const { isPlaying, currentTrack, queue, volume, setIsPlaying, setVolume, nextTrack } = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$lib$2f$store$2f$radio$2e$ts__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useRadioStore"])();
    const { play, pause, skip } = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$lib$2f$apple$2d$music$2f$player$2e$tsx__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useAppleMusic"])();
    const [isMuted, setIsMuted] = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useState"])(false);
    const [progress, setProgress] = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useState"])(0);
    const [duration, setDuration] = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useState"])(0);
    const [audioError, setAudioError] = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useState"])(null);
    const [useHtml5Audio, setUseHtml5Audio] = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useState"])(false);
    const audioRef = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useRef"])(null);
    const progressInterval = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useRef"])(null);
    // Detect if we should use HTML5 audio (demo tracks)
    (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useEffect"])({
        "Player.useEffect": ()=>{
            if (currentTrack?.previewUrl?.includes('pixabay.com')) {
                setUseHtml5Audio(true);
            } else {
                setUseHtml5Audio(false);
            }
        }
    }["Player.useEffect"], [
        currentTrack
    ]);
    // HTML5 Audio for demo tracks
    (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useEffect"])({
        "Player.useEffect": ()=>{
            if (!useHtml5Audio || !currentTrack?.previewUrl) return;
            console.log('Setting up HTML5 audio for:', currentTrack.previewUrl);
            if (!audioRef.current) {
                audioRef.current = new Audio();
                audioRef.current.crossOrigin = 'anonymous';
                audioRef.current.addEventListener('ended', {
                    "Player.useEffect": ()=>{
                        console.log('HTML5 audio ended');
                        nextTrack();
                    }
                }["Player.useEffect"]);
                audioRef.current.addEventListener('canplay', {
                    "Player.useEffect": ()=>{
                        console.log('HTML5 audio can play');
                    }
                }["Player.useEffect"]);
                audioRef.current.addEventListener('error', {
                    "Player.useEffect": (e)=>{
                        console.log('HTML5 audio error:', audioRef.current?.error);
                    }
                }["Player.useEffect"]);
            }
            audioRef.current.src = currentTrack.previewUrl;
            audioRef.current.load();
            if (isPlaying) {
                audioRef.current.play().catch({
                    "Player.useEffect": (e)=>{
                        console.log('HTML5 play error:', e);
                        setAudioError('Click play to enable audio');
                    }
                }["Player.useEffect"]);
            }
            return ({
                "Player.useEffect": ()=>{
                    if (audioRef.current) {
                        audioRef.current.pause();
                        audioRef.current.src = '';
                    }
                }
            })["Player.useEffect"];
        }
    }["Player.useEffect"], [
        useHtml5Audio,
        currentTrack,
        isPlaying,
        nextTrack
    ]);
    // Play/Pause for HTML5 audio
    (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useEffect"])({
        "Player.useEffect": ()=>{
            if (!useHtml5Audio || !audioRef.current) return;
            if (isPlaying) {
                audioRef.current.play().catch({
                    "Player.useEffect": (e)=>{
                        console.log('HTML5 play error:', e);
                    }
                }["Player.useEffect"]);
            } else {
                audioRef.current.pause();
            }
        }
    }["Player.useEffect"], [
        isPlaying,
        useHtml5Audio
    ]);
    // Progress tracking for HTML5 audio
    (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useEffect"])({
        "Player.useEffect": ()=>{
            if (!useHtml5Audio) return;
            progressInterval.current = setInterval({
                "Player.useEffect": ()=>{
                    if (audioRef.current) {
                        setProgress(audioRef.current.currentTime);
                        setDuration(audioRef.current.duration || 0);
                    }
                }
            }["Player.useEffect"], 500);
            return ({
                "Player.useEffect": ()=>{
                    if (progressInterval.current) {
                        clearInterval(progressInterval.current);
                    }
                }
            })["Player.useEffect"];
        }
    }["Player.useEffect"], [
        useHtml5Audio
    ]);
    // Volume for HTML5 audio
    (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useEffect"])({
        "Player.useEffect": ()=>{
            if (audioRef.current) {
                audioRef.current.volume = isMuted ? 0 : volume;
            }
        }
    }["Player.useEffect"], [
        volume,
        isMuted
    ]);
    const handleSeek = (e)=>{
        const time = parseFloat(e.target.value);
        if (useHtml5Audio && audioRef.current) {
            audioRef.current.currentTime = time;
            setProgress(time);
        }
    };
    const handlePlayPause = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useCallback"])({
        "Player.useCallback[handlePlayPause]": ()=>{
            if (useHtml5Audio) {
                if (isPlaying) {
                    audioRef.current?.pause();
                    setIsPlaying(false);
                } else {
                    audioRef.current?.play().catch({
                        "Player.useCallback[handlePlayPause]": (e)=>{
                            console.log('Play error:', e);
                            setAudioError('Click failed. Try again.');
                        }
                    }["Player.useCallback[handlePlayPause]"]);
                    setIsPlaying(true);
                }
            } else {
                // Use Apple Music controls
                if (isPlaying) {
                    pause();
                    setIsPlaying(false);
                } else {
                    play();
                    setIsPlaying(true);
                }
            }
        }
    }["Player.useCallback[handlePlayPause]"], [
        useHtml5Audio,
        isPlaying,
        setIsPlaying,
        play,
        pause
    ]);
    const handleNext = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useCallback"])({
        "Player.useCallback[handleNext]": ()=>{
            // Dispatch skip event for tracking
            if ("TURBOPACK compile-time truthy", 1) {
                window.dispatchEvent(new CustomEvent('raydo:skip'));
            }
            if (useHtml5Audio) {
                nextTrack();
            } else {
                skip();
                nextTrack();
            }
        }
    }["Player.useCallback[handleNext]"], [
        useHtml5Audio,
        skip,
        nextTrack
    ]);
    const handlePrev = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useCallback"])({
        "Player.useCallback[handlePrev]": ()=>{
            // Apple Music doesn't have a reliable "previous" - just restart current
            if (useHtml5Audio && audioRef.current) {
                audioRef.current.currentTime = 0;
                setProgress(0);
            }
        }
    }["Player.useCallback[handlePrev]"], [
        useHtml5Audio
    ]);
    const formatTime = (seconds)=>{
        const mins = Math.floor(seconds / 60);
        const secs = Math.floor(seconds % 60);
        return `${mins}:${secs.toString().padStart(2, '0')}`;
    };
    const displayTrack = currentTrack || (queue.length > 0 ? queue[0] : null);
    return /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
        className: "fixed bottom-0 left-0 right-0 bg-zinc-900 border-t border-zinc-800 p-4 z-50",
        children: [
            useHtml5Audio && /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                className: "mb-2 text-xs text-yellow-400",
                children: "🎵 Demo Tracks (Pixabay)"
            }, void 0, false, {
                fileName: "[project]/clawd/ai-radio-dj/app/components/Player.tsx",
                lineNumber: 184,
                columnNumber: 9
            }, this),
            audioError && /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                className: "mb-2 p-2 bg-red-500/20 text-red-400 text-xs rounded flex items-center justify-between",
                children: [
                    /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("span", {
                        children: audioError
                    }, void 0, false, {
                        fileName: "[project]/clawd/ai-radio-dj/app/components/Player.tsx",
                        lineNumber: 192,
                        columnNumber: 11
                    }, this),
                    /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("button", {
                        onClick: ()=>setAudioError(null),
                        className: "text-red-300",
                        children: "×"
                    }, void 0, false, {
                        fileName: "[project]/clawd/ai-radio-dj/app/components/Player.tsx",
                        lineNumber: 193,
                        columnNumber: 11
                    }, this)
                ]
            }, void 0, true, {
                fileName: "[project]/clawd/ai-radio-dj/app/components/Player.tsx",
                lineNumber: 191,
                columnNumber: 9
            }, this),
            /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                className: "flex items-center gap-4 mb-4",
                children: [
                    displayTrack?.artworkUrl && /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("img", {
                        src: displayTrack.artworkUrl,
                        alt: displayTrack.title,
                        className: "w-16 h-16 rounded-lg object-cover",
                        onError: (e)=>{
                            e.target.style.display = 'none';
                        }
                    }, void 0, false, {
                        fileName: "[project]/clawd/ai-radio-dj/app/components/Player.tsx",
                        lineNumber: 200,
                        columnNumber: 11
                    }, this),
                    /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                        className: "flex-1",
                        children: [
                            /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("h3", {
                                className: "text-white font-medium",
                                children: displayTrack?.title || 'No track playing'
                            }, void 0, false, {
                                fileName: "[project]/clawd/ai-radio-dj/app/components/Player.tsx",
                                lineNumber: 210,
                                columnNumber: 11
                            }, this),
                            /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("p", {
                                className: "text-zinc-400 text-sm",
                                children: displayTrack?.artistName || 'Click Start AI Radio'
                            }, void 0, false, {
                                fileName: "[project]/clawd/ai-radio-dj/app/components/Player.tsx",
                                lineNumber: 211,
                                columnNumber: 11
                            }, this)
                        ]
                    }, void 0, true, {
                        fileName: "[project]/clawd/ai-radio-dj/app/components/Player.tsx",
                        lineNumber: 209,
                        columnNumber: 9
                    }, this)
                ]
            }, void 0, true, {
                fileName: "[project]/clawd/ai-radio-dj/app/components/Player.tsx",
                lineNumber: 198,
                columnNumber: 7
            }, this),
            /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                className: "mb-4",
                children: [
                    /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("input", {
                        type: "range",
                        min: 0,
                        max: duration || 100,
                        value: progress,
                        onChange: handleSeek,
                        className: "w-full h-1 bg-zinc-700 rounded-lg appearance-none cursor-pointer accent-white"
                    }, void 0, false, {
                        fileName: "[project]/clawd/ai-radio-dj/app/components/Player.tsx",
                        lineNumber: 217,
                        columnNumber: 9
                    }, this),
                    /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                        className: "flex justify-between text-xs text-zinc-500 mt-1",
                        children: [
                            /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("span", {
                                children: formatTime(progress)
                            }, void 0, false, {
                                fileName: "[project]/clawd/ai-radio-dj/app/components/Player.tsx",
                                lineNumber: 226,
                                columnNumber: 11
                            }, this),
                            /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("span", {
                                children: formatTime(duration)
                            }, void 0, false, {
                                fileName: "[project]/clawd/ai-radio-dj/app/components/Player.tsx",
                                lineNumber: 227,
                                columnNumber: 11
                            }, this)
                        ]
                    }, void 0, true, {
                        fileName: "[project]/clawd/ai-radio-dj/app/components/Player.tsx",
                        lineNumber: 225,
                        columnNumber: 9
                    }, this)
                ]
            }, void 0, true, {
                fileName: "[project]/clawd/ai-radio-dj/app/components/Player.tsx",
                lineNumber: 216,
                columnNumber: 7
            }, this),
            /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                className: "flex items-center justify-between",
                children: [
                    /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                        className: "flex items-center gap-2",
                        children: [
                            /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("button", {
                                onClick: handlePrev,
                                className: "p-2 text-zinc-400 hover:text-white transition-colors",
                                children: /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])(__TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$lucide$2d$react$2f$dist$2f$esm$2f$icons$2f$skip$2d$back$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__$3c$export__default__as__SkipBack$3e$__["SkipBack"], {
                                    size: 20
                                }, void 0, false, {
                                    fileName: "[project]/clawd/ai-radio-dj/app/components/Player.tsx",
                                    lineNumber: 238,
                                    columnNumber: 13
                                }, this)
                            }, void 0, false, {
                                fileName: "[project]/clawd/ai-radio-dj/app/components/Player.tsx",
                                lineNumber: 234,
                                columnNumber: 11
                            }, this),
                            /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("button", {
                                onClick: handlePlayPause,
                                className: "p-3 bg-white rounded-full text-black hover:bg-zinc-200 transition-colors flex items-center justify-center",
                                children: isPlaying ? /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])(__TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$lucide$2d$react$2f$dist$2f$esm$2f$icons$2f$pause$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__$3c$export__default__as__Pause$3e$__["Pause"], {
                                    size: 24,
                                    fill: "currentColor"
                                }, void 0, false, {
                                    fileName: "[project]/clawd/ai-radio-dj/app/components/Player.tsx",
                                    lineNumber: 244,
                                    columnNumber: 26
                                }, this) : /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])(__TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$lucide$2d$react$2f$dist$2f$esm$2f$icons$2f$play$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__$3c$export__default__as__Play$3e$__["Play"], {
                                    size: 24,
                                    fill: "currentColor"
                                }, void 0, false, {
                                    fileName: "[project]/clawd/ai-radio-dj/app/components/Player.tsx",
                                    lineNumber: 244,
                                    columnNumber: 68
                                }, this)
                            }, void 0, false, {
                                fileName: "[project]/clawd/ai-radio-dj/app/components/Player.tsx",
                                lineNumber: 240,
                                columnNumber: 11
                            }, this),
                            /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("button", {
                                onClick: handleNext,
                                className: "p-2 text-zinc-400 hover:text-white transition-colors",
                                children: /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])(__TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$lucide$2d$react$2f$dist$2f$esm$2f$icons$2f$skip$2d$forward$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__$3c$export__default__as__SkipForward$3e$__["SkipForward"], {
                                    size: 20
                                }, void 0, false, {
                                    fileName: "[project]/clawd/ai-radio-dj/app/components/Player.tsx",
                                    lineNumber: 250,
                                    columnNumber: 13
                                }, this)
                            }, void 0, false, {
                                fileName: "[project]/clawd/ai-radio-dj/app/components/Player.tsx",
                                lineNumber: 246,
                                columnNumber: 11
                            }, this)
                        ]
                    }, void 0, true, {
                        fileName: "[project]/clawd/ai-radio-dj/app/components/Player.tsx",
                        lineNumber: 233,
                        columnNumber: 9
                    }, this),
                    /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                        className: "flex items-center gap-2",
                        children: [
                            /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("button", {
                                onClick: ()=>setIsMuted(!isMuted),
                                className: "p-2 text-zinc-400 hover:text-white transition-colors",
                                children: isMuted ? /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])(__TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$lucide$2d$react$2f$dist$2f$esm$2f$icons$2f$volume$2d$x$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__$3c$export__default__as__VolumeX$3e$__["VolumeX"], {
                                    size: 20
                                }, void 0, false, {
                                    fileName: "[project]/clawd/ai-radio-dj/app/components/Player.tsx",
                                    lineNumber: 259,
                                    columnNumber: 24
                                }, this) : /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])(__TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$lucide$2d$react$2f$dist$2f$esm$2f$icons$2f$volume$2d$2$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__$3c$export__default__as__Volume2$3e$__["Volume2"], {
                                    size: 20
                                }, void 0, false, {
                                    fileName: "[project]/clawd/ai-radio-dj/app/components/Player.tsx",
                                    lineNumber: 259,
                                    columnNumber: 48
                                }, this)
                            }, void 0, false, {
                                fileName: "[project]/clawd/ai-radio-dj/app/components/Player.tsx",
                                lineNumber: 255,
                                columnNumber: 11
                            }, this),
                            /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("input", {
                                type: "range",
                                min: 0,
                                max: 1,
                                step: 0.1,
                                value: isMuted ? 0 : volume,
                                onChange: (e)=>setVolume(parseFloat(e.target.value)),
                                className: "w-24 h-1 bg-zinc-700 rounded-lg appearance-none cursor-pointer accent-white"
                            }, void 0, false, {
                                fileName: "[project]/clawd/ai-radio-dj/app/components/Player.tsx",
                                lineNumber: 261,
                                columnNumber: 11
                            }, this)
                        ]
                    }, void 0, true, {
                        fileName: "[project]/clawd/ai-radio-dj/app/components/Player.tsx",
                        lineNumber: 254,
                        columnNumber: 9
                    }, this)
                ]
            }, void 0, true, {
                fileName: "[project]/clawd/ai-radio-dj/app/components/Player.tsx",
                lineNumber: 232,
                columnNumber: 7
            }, this)
        ]
    }, void 0, true, {
        fileName: "[project]/clawd/ai-radio-dj/app/components/Player.tsx",
        lineNumber: 181,
        columnNumber: 5
    }, this);
}
_s(Player, "QzaopSXJ0BaDdm8prSIfrCc+Nh0=", false, function() {
    return [
        __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$lib$2f$store$2f$radio$2e$ts__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useRadioStore"],
        __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$lib$2f$apple$2d$music$2f$player$2e$tsx__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useAppleMusic"]
    ];
});
_c = Player;
var _c;
__turbopack_context__.k.register(_c, "Player");
if (typeof globalThis.$RefreshHelpers$ === 'object' && globalThis.$RefreshHelpers !== null) {
    __turbopack_context__.k.registerExports(__turbopack_context__.m, globalThis.$RefreshHelpers$);
}
}),
"[project]/clawd/ai-radio-dj/app/components/Visualizer.tsx [app-client] (ecmascript)", ((__turbopack_context__) => {
"use strict";

__turbopack_context__.s([
    "Visualizer",
    ()=>Visualizer
]);
var __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__ = __turbopack_context__.i("[project]/clawd/ai-radio-dj/node_modules/next/dist/compiled/react/jsx-dev-runtime.js [app-client] (ecmascript)");
var __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__ = __turbopack_context__.i("[project]/clawd/ai-radio-dj/node_modules/next/dist/compiled/react/index.js [app-client] (ecmascript)");
;
var _s = __turbopack_context__.k.signature();
'use client';
;
function Visualizer({ isPlaying }) {
    _s();
    const canvasRef = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useRef"])(null);
    const animationRef = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useRef"])();
    (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useEffect"])({
        "Visualizer.useEffect": ()=>{
            const canvas = canvasRef.current;
            if (!canvas) return;
            const ctx = canvas.getContext('2d');
            if (!ctx) return;
            const bars = 64;
            const barWidth = canvas.width / bars - 2;
            const animate = {
                "Visualizer.useEffect.animate": ()=>{
                    if (!isPlaying) {
                        ctx.fillStyle = '#18181b';
                        ctx.fillRect(0, 0, canvas.width, canvas.height);
                        animationRef.current = requestAnimationFrame(animate);
                        return;
                    }
                    // Clear with fade effect
                    ctx.fillStyle = 'rgba(24, 24, 27, 0.2)';
                    ctx.fillRect(0, 0, canvas.width, canvas.height);
                    for(let i = 0; i < bars; i++){
                        // Simulated frequency data based on time
                        const time = Date.now() / 1000;
                        const height = Math.sin(time * 2 + i * 0.3) * 30 + Math.sin(time * 3 + i * 0.5) * 20 + Math.random() * 30 + 20;
                        const hue = (i * 5 + time * 20) % 360;
                        const x = i * (barWidth + 2);
                        const y = canvas.height - height;
                        ctx.fillStyle = `hsla(${hue}, 70%, 60%, 0.8)`;
                        ctx.fillRect(x, y, barWidth, height);
                        // Glow effect
                        ctx.shadowBlur = 10;
                        ctx.shadowColor = `hsla(${hue}, 70%, 60%, 0.5)`;
                    }
                    animationRef.current = requestAnimationFrame(animate);
                }
            }["Visualizer.useEffect.animate"];
            animate();
            return ({
                "Visualizer.useEffect": ()=>{
                    if (animationRef.current) {
                        cancelAnimationFrame(animationRef.current);
                    }
                }
            })["Visualizer.useEffect"];
        }
    }["Visualizer.useEffect"], [
        isPlaying
    ]);
    return /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("canvas", {
        ref: canvasRef,
        width: 800,
        height: 200,
        className: "w-full h-48 rounded-xl",
        style: {
            background: '#18181b'
        }
    }, void 0, false, {
        fileName: "[project]/clawd/ai-radio-dj/app/components/Visualizer.tsx",
        lineNumber: 63,
        columnNumber: 5
    }, this);
}
_s(Visualizer, "X5bd7Q1XXg1keIMflMhOltk4wyU=");
_c = Visualizer;
var _c;
__turbopack_context__.k.register(_c, "Visualizer");
if (typeof globalThis.$RefreshHelpers$ === 'object' && globalThis.$RefreshHelpers !== null) {
    __turbopack_context__.k.registerExports(__turbopack_context__.m, globalThis.$RefreshHelpers$);
}
}),
"[project]/clawd/ai-radio-dj/app/page.tsx [app-client] (ecmascript)", ((__turbopack_context__) => {
"use strict";

__turbopack_context__.s([
    "default",
    ()=>Home
]);
var __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__ = __turbopack_context__.i("[project]/clawd/ai-radio-dj/node_modules/next/dist/compiled/react/jsx-dev-runtime.js [app-client] (ecmascript)");
var __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__ = __turbopack_context__.i("[project]/clawd/ai-radio-dj/node_modules/next/dist/compiled/react/index.js [app-client] (ecmascript)");
var __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$app$2f$components$2f$Settings$2e$tsx__$5b$app$2d$client$5d$__$28$ecmascript$29$__ = __turbopack_context__.i("[project]/clawd/ai-radio-dj/app/components/Settings.tsx [app-client] (ecmascript)");
var __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$app$2f$components$2f$Player$2e$tsx__$5b$app$2d$client$5d$__$28$ecmascript$29$__ = __turbopack_context__.i("[project]/clawd/ai-radio-dj/app/components/Player.tsx [app-client] (ecmascript)");
var __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$app$2f$components$2f$Visualizer$2e$tsx__$5b$app$2d$client$5d$__$28$ecmascript$29$__ = __turbopack_context__.i("[project]/clawd/ai-radio-dj/app/components/Visualizer.tsx [app-client] (ecmascript)");
var __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$lib$2f$store$2f$radio$2e$ts__$5b$app$2d$client$5d$__$28$ecmascript$29$__ = __turbopack_context__.i("[project]/clawd/ai-radio-dj/lib/store/radio.ts [app-client] (ecmascript)");
var __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$lib$2f$apple$2d$music$2f$player$2e$tsx__$5b$app$2d$client$5d$__$28$ecmascript$29$__ = __turbopack_context__.i("[project]/clawd/ai-radio-dj/lib/apple-music/player.tsx [app-client] (ecmascript)");
;
var _s = __turbopack_context__.k.signature(), _s1 = __turbopack_context__.k.signature();
'use client';
;
;
;
;
;
;
const GENRES = [
    'pop',
    'rock',
    'hip-hop',
    'electronic',
    'jazz',
    'classical',
    'r&b',
    'country',
    'indie',
    'alternative',
    'metal',
    'punk',
    'reggae',
    'blues',
    'lo-fi',
    'chill',
    'ambient',
    'dance',
    'latin',
    'folk',
    'acoustic',
    // Latin genres
    'salsa',
    'reggae',
    'bachata',
    'merengue',
    'cumbia',
    'latin pop',
    'latin rock',
    'timba',
    'bolero',
    'vallenato',
    'banda',
    'ranchera',
    'norteño',
    'corridos',
    'urbano latino',
    'dembow',
    'latin hip-hop'
];
const POPULAR_ARTISTS = [
    'Drake',
    'Taylor Swift',
    'The Weeknd',
    'Bad Bunny',
    'Ed Sheeran',
    'Dua Lipa',
    'Post Malone',
    'Billie Eilish',
    'Harry Styles',
    'Beyoncé',
    'Kendrick Lamar',
    'Ariana Grande',
    'Bruno Mars',
    'SZA',
    'Travis Scott',
    // Latin artists
    'J Balvin',
    'Daddy Yankee',
    'Ozuna',
    'Karol G',
    'Rauw Alejandro',
    'Romeo Santos',
    'Aventura',
    'Marc Anthony',
    'Shakira',
    'Enrique Iglesias',
    'Wisin',
    'Yandel',
    'Farruko',
    'Natti Natasha',
    'Becky G',
    'Maluma',
    'Feid',
    'Peso Pluma',
    'Grupo Frontera',
    'Fuerza Regida',
    'Los Tigres del Norte',
    'Calibre 50',
    'Junior H',
    'Natanael Cano',
    'Yng Lvcas',
    'Xavi'
];
function AppleMusicDashboard() {
    _s();
    const { user, isAuthenticated, playlists = [], connectAppleMusic, disconnect, createRadioStation, isLoading, error } = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$lib$2f$apple$2d$music$2f$player$2e$tsx__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useAppleMusic"])();
    const { isPlaying, currentTrack } = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$lib$2f$store$2f$radio$2e$ts__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useRadioStore"])();
    const [selectedMood, setSelectedMood] = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useState"])('balanced');
    const [selectedGenres, setSelectedGenres] = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useState"])([
        'pop'
    ]);
    const [artistQuery, setArtistQuery] = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useState"])('');
    const [customArtists, setCustomArtists] = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useState"])([]);
    const [showCustomize, setShowCustomize] = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useState"])(false);
    const [timeSuggestion, setTimeSuggestion] = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useState"])(null);
    // Time-based mood suggestion
    (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useEffect"])({
        "AppleMusicDashboard.useEffect": ()=>{
            const hour = new Date().getHours();
            // Morning (5-11): chill/start fresh
            if (hour >= 5 && hour < 11) {
                setTimeSuggestion('chill');
            } else if (hour >= 11 && hour < 17) {
                setTimeSuggestion('balanced');
            } else {
                setTimeSuggestion('hype');
            }
        }
    }["AppleMusicDashboard.useEffect"], []);
    if (!isAuthenticated) {
        return /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])(__TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["Fragment"], {
            children: [
                /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                    className: "mb-4 p-6 bg-gradient-to-r from-red-500/10 to-red-600/10 border border-red-500/20 rounded-xl",
                    children: [
                        /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                            className: "flex items-center justify-between",
                            children: [
                                /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                                    children: [
                                        /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("h3", {
                                            className: "text-lg font-semibold text-red-400 mb-1",
                                            children: "🎧 Apple Music"
                                        }, void 0, false, {
                                            fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                            lineNumber: 68,
                                            columnNumber: 15
                                        }, this),
                                        /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("p", {
                                            className: "text-zinc-400",
                                            children: "Sign in with Apple Music to stream real music"
                                        }, void 0, false, {
                                            fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                            lineNumber: 69,
                                            columnNumber: 15
                                        }, this)
                                    ]
                                }, void 0, true, {
                                    fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                    lineNumber: 67,
                                    columnNumber: 13
                                }, this),
                                /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("button", {
                                    onClick: connectAppleMusic,
                                    className: "px-6 py-3 bg-gradient-to-r from-red-500 to-pink-500 hover:from-red-400 hover:to-pink-400 text-white font-semibold rounded-lg transition-colors",
                                    children: "Connect"
                                }, void 0, false, {
                                    fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                    lineNumber: 71,
                                    columnNumber: 15
                                }, this)
                            ]
                        }, void 0, true, {
                            fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                            lineNumber: 66,
                            columnNumber: 11
                        }, this),
                        error && /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                            className: "mt-4 p-3 bg-red-500/20 border border-red-500/30 rounded-lg",
                            children: /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("p", {
                                className: "text-red-400 text-sm",
                                children: error
                            }, void 0, false, {
                                fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                lineNumber: 80,
                                columnNumber: 15
                            }, this)
                        }, void 0, false, {
                            fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                            lineNumber: 79,
                            columnNumber: 13
                        }, this)
                    ]
                }, void 0, true, {
                    fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                    lineNumber: 65,
                    columnNumber: 9
                }, this),
                /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                    className: "mb-8 p-6 bg-gradient-to-r from-green-500/10 to-green-600/10 border border-green-500/20 rounded-xl opacity-75",
                    children: /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                        className: "flex items-center justify-between",
                        children: [
                            /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                                children: [
                                    /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("h3", {
                                        className: "text-lg font-semibold text-green-400 mb-1",
                                        children: "🎵 Spotify"
                                    }, void 0, false, {
                                        fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                        lineNumber: 89,
                                        columnNumber: 15
                                    }, this),
                                    /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("p", {
                                        className: "text-zinc-400",
                                        children: "Connect your Spotify library for AI radio"
                                    }, void 0, false, {
                                        fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                        lineNumber: 90,
                                        columnNumber: 15
                                    }, this)
                                ]
                            }, void 0, true, {
                                fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                lineNumber: 88,
                                columnNumber: 13
                            }, this),
                            /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("button", {
                                onClick: ()=>alert('Spotify integration coming soon!'),
                                className: "px-6 py-3 bg-zinc-800 text-zinc-500 font-semibold rounded-lg cursor-not-allowed",
                                children: "Coming Soon"
                            }, void 0, false, {
                                fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                lineNumber: 92,
                                columnNumber: 15
                            }, this)
                        ]
                    }, void 0, true, {
                        fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                        lineNumber: 87,
                        columnNumber: 11
                    }, this)
                }, void 0, false, {
                    fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                    lineNumber: 86,
                    columnNumber: 9
                }, this)
            ]
        }, void 0, true);
    }
    const handleGenreToggle = (genre)=>{
        setSelectedGenres((prev)=>prev.includes(genre) ? prev.filter((g)=>g !== genre) : [
                ...prev,
                genre
            ].slice(0, 3));
    };
    const handleAddArtist = ()=>{
        if (artistQuery.trim() && !customArtists.includes(artistQuery.trim())) {
            setCustomArtists((prev)=>[
                    ...prev,
                    artistQuery.trim()
                ].slice(0, 5));
            setArtistQuery('');
        }
    };
    const handleRemoveArtist = (artist)=>{
        setCustomArtists((prev)=>prev.filter((a)=>a !== artist));
    };
    const handleCreateStation = ()=>{
        // Combine mood, genres, and artists
        const stationConfig = {
            mood: selectedMood,
            genres: selectedGenres,
            artists: customArtists
        };
        console.log('Creating station with:', stationConfig);
        createRadioStation(selectedMood);
    };
    return /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])(__TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["Fragment"], {
        children: [
            /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                className: "mb-8 p-4 bg-zinc-900/50 rounded-xl flex items-center gap-4",
                children: [
                    /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                        className: "w-12 h-12 bg-gradient-to-br from-red-500 to-pink-500 rounded-full flex items-center justify-center text-white font-bold",
                        children: user?.name?.charAt(0) || 'A'
                    }, void 0, false, {
                        fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                        lineNumber: 138,
                        columnNumber: 9
                    }, this),
                    /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                        className: "flex-1",
                        children: [
                            /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("p", {
                                className: "text-zinc-400 text-sm",
                                children: "Signed in with Apple Music"
                            }, void 0, false, {
                                fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                lineNumber: 142,
                                columnNumber: 11
                            }, this),
                            /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("p", {
                                className: "text-white font-medium",
                                children: user?.name
                            }, void 0, false, {
                                fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                lineNumber: 143,
                                columnNumber: 11
                            }, this)
                        ]
                    }, void 0, true, {
                        fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                        lineNumber: 141,
                        columnNumber: 9
                    }, this),
                    /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("button", {
                        onClick: disconnect,
                        className: "px-4 py-2 bg-zinc-800 hover:bg-zinc-700 text-zinc-300 rounded-lg text-sm",
                        children: "Disconnect"
                    }, void 0, false, {
                        fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                        lineNumber: 145,
                        columnNumber: 9
                    }, this)
                ]
            }, void 0, true, {
                fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                lineNumber: 137,
                columnNumber: 7
            }, this),
            /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                className: "mb-8 p-6 bg-zinc-900/50 rounded-xl",
                children: [
                    /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                        className: "flex items-center justify-between mb-4",
                        children: [
                            /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("h3", {
                                className: "text-lg font-semibold text-white",
                                children: "🎛️ Customize Your Station"
                            }, void 0, false, {
                                fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                lineNumber: 156,
                                columnNumber: 11
                            }, this),
                            /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("button", {
                                onClick: ()=>setShowCustomize(!showCustomize),
                                className: "text-zinc-400 hover:text-white text-sm",
                                children: showCustomize ? 'Hide' : 'Customize'
                            }, void 0, false, {
                                fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                lineNumber: 157,
                                columnNumber: 11
                            }, this)
                        ]
                    }, void 0, true, {
                        fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                        lineNumber: 155,
                        columnNumber: 9
                    }, this),
                    showCustomize && /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                        className: "space-y-6",
                        children: [
                            /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                                children: [
                                    /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("p", {
                                        className: "text-zinc-400 text-sm mb-2",
                                        children: "🎭 Mood"
                                    }, void 0, false, {
                                        fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                        lineNumber: 169,
                                        columnNumber: 15
                                    }, this),
                                    /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                                        className: "flex gap-3 flex-wrap",
                                        children: [
                                            'chill',
                                            'balanced',
                                            'hype'
                                        ].map((mood)=>/*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("button", {
                                                onClick: ()=>setSelectedMood(mood),
                                                className: `px-4 py-2 rounded-lg font-medium transition-colors ${selectedMood === mood ? 'bg-purple-500 text-white' : 'bg-zinc-800 text-zinc-400 hover:bg-zinc-700'}`,
                                                children: [
                                                    mood === 'chill' && '🌀 Chill',
                                                    mood === 'balanced' && '⚖️ Balanced',
                                                    mood === 'hype' && '⚡ Hype'
                                                ]
                                            }, mood, true, {
                                                fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                                lineNumber: 172,
                                                columnNumber: 19
                                            }, this))
                                    }, void 0, false, {
                                        fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                        lineNumber: 170,
                                        columnNumber: 15
                                    }, this),
                                    timeSuggestion && timeSuggestion !== selectedMood && /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("button", {
                                        onClick: ()=>setSelectedMood(timeSuggestion),
                                        className: "mt-2 text-xs text-purple-400 hover:text-purple-300 transition-colors",
                                        children: [
                                            "💡 ",
                                            timeSuggestion === 'chill' ? 'Morning vibes?' : timeSuggestion === 'hype' ? 'Night owl energy?' : 'Afternoon mix?',
                                            " Click to apply"
                                        ]
                                    }, void 0, true, {
                                        fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                        lineNumber: 188,
                                        columnNumber: 17
                                    }, this)
                                ]
                            }, void 0, true, {
                                fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                lineNumber: 168,
                                columnNumber: 13
                            }, this),
                            /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                                children: [
                                    /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("p", {
                                        className: "text-zinc-400 text-sm mb-2",
                                        children: "🎸 Genres (select up to 3)"
                                    }, void 0, false, {
                                        fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                        lineNumber: 199,
                                        columnNumber: 15
                                    }, this),
                                    /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                                        className: "flex gap-2 flex-wrap",
                                        children: GENRES.slice(0, 15).map((genre)=>/*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("button", {
                                                onClick: ()=>handleGenreToggle(genre),
                                                className: `px-3 py-1 rounded-full text-sm transition-colors ${selectedGenres.includes(genre) ? 'bg-red-500 text-white' : 'bg-zinc-800 text-zinc-400 hover:bg-zinc-700'}`,
                                                children: genre
                                            }, genre, false, {
                                                fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                                lineNumber: 202,
                                                columnNumber: 19
                                            }, this))
                                    }, void 0, false, {
                                        fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                        lineNumber: 200,
                                        columnNumber: 15
                                    }, this),
                                    /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("p", {
                                        className: "text-zinc-500 text-xs mt-2",
                                        children: [
                                            "Selected: ",
                                            selectedGenres.join(', ') || 'none'
                                        ]
                                    }, void 0, true, {
                                        fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                        lineNumber: 215,
                                        columnNumber: 15
                                    }, this)
                                ]
                            }, void 0, true, {
                                fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                lineNumber: 198,
                                columnNumber: 13
                            }, this),
                            /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                                children: [
                                    /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("p", {
                                        className: "text-zinc-400 text-sm mb-2",
                                        children: "👤 Add Artists"
                                    }, void 0, false, {
                                        fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                        lineNumber: 220,
                                        columnNumber: 15
                                    }, this),
                                    /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                                        className: "flex gap-2 mb-2",
                                        children: [
                                            /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("input", {
                                                type: "text",
                                                value: artistQuery,
                                                onChange: (e)=>setArtistQuery(e.target.value),
                                                onKeyDown: (e)=>e.key === 'Enter' && handleAddArtist(),
                                                placeholder: "Search for an artist...",
                                                className: "flex-1 bg-zinc-800 text-white px-4 py-2 rounded-lg focus:outline-none focus:ring-2 focus:ring-red-500"
                                            }, void 0, false, {
                                                fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                                lineNumber: 222,
                                                columnNumber: 17
                                            }, this),
                                            /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("button", {
                                                onClick: handleAddArtist,
                                                className: "px-4 py-2 bg-zinc-700 hover:bg-zinc-600 text-white rounded-lg",
                                                children: "Add"
                                            }, void 0, false, {
                                                fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                                lineNumber: 230,
                                                columnNumber: 17
                                            }, this)
                                        ]
                                    }, void 0, true, {
                                        fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                        lineNumber: 221,
                                        columnNumber: 15
                                    }, this),
                                    /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                                        className: "mb-3",
                                        children: [
                                            /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("p", {
                                                className: "text-zinc-500 text-xs mb-2",
                                                children: "Popular:"
                                            }, void 0, false, {
                                                fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                                lineNumber: 240,
                                                columnNumber: 17
                                            }, this),
                                            /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                                                className: "flex gap-2 flex-wrap",
                                                children: POPULAR_ARTISTS.slice(0, 8).map((artist)=>/*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("button", {
                                                        onClick: ()=>{
                                                            if (!customArtists.includes(artist)) {
                                                                setCustomArtists((prev)=>[
                                                                        ...prev,
                                                                        artist
                                                                    ].slice(0, 5));
                                                            }
                                                        },
                                                        className: "px-2 py-1 bg-zinc-800 hover:bg-zinc-700 text-zinc-400 text-xs rounded",
                                                        children: [
                                                            "+ ",
                                                            artist
                                                        ]
                                                    }, artist, true, {
                                                        fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                                        lineNumber: 243,
                                                        columnNumber: 21
                                                    }, this))
                                            }, void 0, false, {
                                                fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                                lineNumber: 241,
                                                columnNumber: 17
                                            }, this)
                                        ]
                                    }, void 0, true, {
                                        fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                        lineNumber: 239,
                                        columnNumber: 15
                                    }, this),
                                    customArtists.length > 0 && /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                                        className: "flex gap-2 flex-wrap",
                                        children: customArtists.map((artist)=>/*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("span", {
                                                className: "flex items-center gap-2 px-3 py-1 bg-red-500/20 text-red-400 rounded-full text-sm",
                                                children: [
                                                    artist,
                                                    /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("button", {
                                                        onClick: ()=>handleRemoveArtist(artist),
                                                        className: "hover:text-white",
                                                        children: "×"
                                                    }, void 0, false, {
                                                        fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                                        lineNumber: 264,
                                                        columnNumber: 23
                                                    }, this)
                                                ]
                                            }, artist, true, {
                                                fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                                lineNumber: 262,
                                                columnNumber: 21
                                            }, this))
                                    }, void 0, false, {
                                        fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                        lineNumber: 260,
                                        columnNumber: 17
                                    }, this)
                                ]
                            }, void 0, true, {
                                fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                lineNumber: 219,
                                columnNumber: 13
                            }, this)
                        ]
                    }, void 0, true, {
                        fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                        lineNumber: 166,
                        columnNumber: 11
                    }, this)
                ]
            }, void 0, true, {
                fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                lineNumber: 154,
                columnNumber: 7
            }, this),
            /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                className: "mb-8 p-6 bg-zinc-900/50 rounded-xl",
                children: [
                    /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("h3", {
                        className: "text-lg font-semibold text-white mb-4",
                        children: "🚀 Quick Start AI Radio"
                    }, void 0, false, {
                        fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                        lineNumber: 276,
                        columnNumber: 9
                    }, this),
                    /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("p", {
                        className: "text-zinc-400 text-sm mb-4",
                        children: [
                            customArtists.length > 0 ? `AI Radio with ${selectedGenres.join(', ')} + ${customArtists.join(', ')}` : `AI Radio mixing ${selectedGenres.join(', ')} songs`,
                            ' ',
                            "- ",
                            selectedMood,
                            " mood with AI commentary"
                        ]
                    }, void 0, true, {
                        fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                        lineNumber: 277,
                        columnNumber: 9
                    }, this),
                    /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("button", {
                        onClick: handleCreateStation,
                        disabled: isLoading || selectedGenres.length === 0,
                        className: "w-full py-3 bg-gradient-to-r from-purple-500 to-pink-500 hover:from-purple-400 hover:to-pink-400 text-white font-semibold rounded-lg transition-colors disabled:opacity-50",
                        children: isLoading ? 'Creating Station...' : '🎵 Start AI Radio'
                    }, void 0, false, {
                        fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                        lineNumber: 285,
                        columnNumber: 9
                    }, this)
                ]
            }, void 0, true, {
                fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                lineNumber: 275,
                columnNumber: 7
            }, this),
            playlists.length > 0 && /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                className: "mb-8",
                children: [
                    /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("h3", {
                        className: "text-lg font-semibold text-white mb-4",
                        children: "📚 Your Playlists"
                    }, void 0, false, {
                        fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                        lineNumber: 297,
                        columnNumber: 11
                    }, this),
                    /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                        className: "grid grid-cols-2 md:grid-cols-4 gap-4",
                        children: playlists.slice(0, 8).map((playlist)=>/*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                                className: "p-4 bg-zinc-900/50 rounded-xl hover:bg-zinc-800 transition-colors cursor-pointer",
                                children: [
                                    playlist.artwork && /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("img", {
                                        src: playlist.artwork.url?.replace('{w}', '200').replace('{h}', '200'),
                                        alt: playlist.name,
                                        className: "w-full aspect-square object-cover rounded-lg mb-3"
                                    }, void 0, false, {
                                        fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                        lineNumber: 305,
                                        columnNumber: 19
                                    }, this),
                                    /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("p", {
                                        className: "text-white font-medium truncate",
                                        children: playlist.name
                                    }, void 0, false, {
                                        fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                        lineNumber: 311,
                                        columnNumber: 17
                                    }, this),
                                    /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("p", {
                                        className: "text-zinc-500 text-sm",
                                        children: [
                                            playlist.trackCount,
                                            " tracks"
                                        ]
                                    }, void 0, true, {
                                        fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                        lineNumber: 312,
                                        columnNumber: 17
                                    }, this)
                                ]
                            }, playlist.id, true, {
                                fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                lineNumber: 300,
                                columnNumber: 15
                            }, this))
                    }, void 0, false, {
                        fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                        lineNumber: 298,
                        columnNumber: 11
                    }, this)
                ]
            }, void 0, true, {
                fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                lineNumber: 296,
                columnNumber: 9
            }, this),
            currentTrack && /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                className: "mb-6 p-4 bg-zinc-900/50 rounded-xl flex items-center gap-4",
                children: [
                    currentTrack.artworkUrl && /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("img", {
                        src: currentTrack.artworkUrl,
                        alt: currentTrack.title,
                        className: "w-16 h-16 rounded-lg"
                    }, void 0, false, {
                        fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                        lineNumber: 323,
                        columnNumber: 13
                    }, this),
                    /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                        className: "flex-1",
                        children: [
                            /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("p", {
                                className: "text-white font-medium",
                                children: currentTrack.title
                            }, void 0, false, {
                                fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                lineNumber: 326,
                                columnNumber: 13
                            }, this),
                            /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("p", {
                                className: "text-zinc-400 text-sm",
                                children: currentTrack.artistName
                            }, void 0, false, {
                                fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                lineNumber: 327,
                                columnNumber: 13
                            }, this)
                        ]
                    }, void 0, true, {
                        fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                        lineNumber: 325,
                        columnNumber: 11
                    }, this),
                    /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                        className: `w-3 h-3 rounded-full ${isPlaying ? 'bg-green-400 animate-pulse' : 'bg-zinc-500'}`
                    }, void 0, false, {
                        fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                        lineNumber: 329,
                        columnNumber: 11
                    }, this)
                ]
            }, void 0, true, {
                fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                lineNumber: 321,
                columnNumber: 9
            }, this)
        ]
    }, void 0, true);
}
_s(AppleMusicDashboard, "srfeEPcGqpzGhpZIg+fruKhGFgg=", false, function() {
    return [
        __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$lib$2f$apple$2d$music$2f$player$2e$tsx__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useAppleMusic"],
        __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$lib$2f$store$2f$radio$2e$ts__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useRadioStore"]
    ];
});
_c = AppleMusicDashboard;
function HomeContent() {
    _s1();
    const { toggleSettings, isPlaying } = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$lib$2f$store$2f$radio$2e$ts__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useRadioStore"])();
    const [isLoading, setIsLoading] = (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useState"])(true);
    (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$index$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useEffect"])({
        "HomeContent.useEffect": ()=>{
            const timer = setTimeout({
                "HomeContent.useEffect.timer": ()=>setIsLoading(false)
            }["HomeContent.useEffect.timer"], 1000);
            return ({
                "HomeContent.useEffect": ()=>clearTimeout(timer)
            })["HomeContent.useEffect"];
        }
    }["HomeContent.useEffect"], []);
    if (isLoading) {
        return /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
            className: "min-h-screen bg-black flex items-center justify-center",
            children: /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                className: "text-center",
                children: [
                    /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                        className: "w-16 h-16 border-4 border-zinc-800 border-t-white rounded-full animate-spin mx-auto mb-4"
                    }, void 0, false, {
                        fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                        lineNumber: 349,
                        columnNumber: 11
                    }, this),
                    /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("p", {
                        className: "text-zinc-400",
                        children: "Loading RAY.DO..."
                    }, void 0, false, {
                        fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                        lineNumber: 350,
                        columnNumber: 11
                    }, this)
                ]
            }, void 0, true, {
                fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                lineNumber: 348,
                columnNumber: 9
            }, this)
        }, void 0, false, {
            fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
            lineNumber: 347,
            columnNumber: 7
        }, this);
    }
    return /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
        className: "min-h-screen bg-black text-white",
        children: [
            /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("header", {
                className: "sticky top-0 z-10 bg-black/80 backdrop-blur-lg border-b border-zinc-800",
                children: /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                    className: "max-w-6xl mx-auto px-6 py-4 flex items-center justify-between",
                    children: [
                        /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                            className: "flex items-center gap-3",
                            children: [
                                /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                                    className: "w-10 h-10 bg-gradient-to-br from-red-500 to-pink-500 rounded-lg flex items-center justify-center",
                                    children: /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("span", {
                                        className: "text-xl",
                                        children: "🎵"
                                    }, void 0, false, {
                                        fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                        lineNumber: 363,
                                        columnNumber: 15
                                    }, this)
                                }, void 0, false, {
                                    fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                    lineNumber: 362,
                                    columnNumber: 13
                                }, this),
                                /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("div", {
                                    children: [
                                        /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("h1", {
                                            className: "text-xl font-bold",
                                            children: "RAY.DO"
                                        }, void 0, false, {
                                            fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                            lineNumber: 366,
                                            columnNumber: 15
                                        }, this),
                                        /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("p", {
                                            className: "text-xs text-zinc-500",
                                            children: "AI Radio DJ with Apple Music"
                                        }, void 0, false, {
                                            fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                            lineNumber: 367,
                                            columnNumber: 15
                                        }, this)
                                    ]
                                }, void 0, true, {
                                    fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                    lineNumber: 365,
                                    columnNumber: 13
                                }, this)
                            ]
                        }, void 0, true, {
                            fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                            lineNumber: 361,
                            columnNumber: 11
                        }, this),
                        /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("button", {
                            onClick: toggleSettings,
                            className: "p-2 text-zinc-400 hover:text-white transition-colors",
                            children: /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("svg", {
                                width: "20",
                                height: "20",
                                viewBox: "0 0 24 24",
                                fill: "none",
                                stroke: "currentColor",
                                strokeWidth: "2",
                                children: /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("circle", {
                                    cx: "12",
                                    cy: "12",
                                    r: "3"
                                }, void 0, false, {
                                    fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                    lineNumber: 376,
                                    columnNumber: 15
                                }, this)
                            }, void 0, false, {
                                fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                                lineNumber: 375,
                                columnNumber: 13
                            }, this)
                        }, void 0, false, {
                            fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                            lineNumber: 371,
                            columnNumber: 11
                        }, this)
                    ]
                }, void 0, true, {
                    fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                    lineNumber: 360,
                    columnNumber: 9
                }, this)
            }, void 0, false, {
                fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                lineNumber: 359,
                columnNumber: 7
            }, this),
            /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])("main", {
                className: "max-w-6xl mx-auto px-6 py-8 pb-32",
                children: [
                    /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])(AppleMusicDashboard, {}, void 0, false, {
                        fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                        lineNumber: 384,
                        columnNumber: 9
                    }, this),
                    /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])(__TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$app$2f$components$2f$Visualizer$2e$tsx__$5b$app$2d$client$5d$__$28$ecmascript$29$__["Visualizer"], {
                        isPlaying: isPlaying
                    }, void 0, false, {
                        fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                        lineNumber: 385,
                        columnNumber: 9
                    }, this)
                ]
            }, void 0, true, {
                fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                lineNumber: 383,
                columnNumber: 7
            }, this),
            /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])(__TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$app$2f$components$2f$Player$2e$tsx__$5b$app$2d$client$5d$__$28$ecmascript$29$__["Player"], {}, void 0, false, {
                fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                lineNumber: 388,
                columnNumber: 7
            }, this),
            /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])(__TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$app$2f$components$2f$Settings$2e$tsx__$5b$app$2d$client$5d$__$28$ecmascript$29$__["Settings"], {}, void 0, false, {
                fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
                lineNumber: 389,
                columnNumber: 7
            }, this)
        ]
    }, void 0, true, {
        fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
        lineNumber: 357,
        columnNumber: 5
    }, this);
}
_s1(HomeContent, "0gK2JvVvRsTJ1VMlc4D9+VAKdnQ=", false, function() {
    return [
        __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$lib$2f$store$2f$radio$2e$ts__$5b$app$2d$client$5d$__$28$ecmascript$29$__["useRadioStore"]
    ];
});
_c1 = HomeContent;
function Home() {
    return /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])(__TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$lib$2f$apple$2d$music$2f$player$2e$tsx__$5b$app$2d$client$5d$__$28$ecmascript$29$__["AppleMusicProvider"], {
        children: /*#__PURE__*/ (0, __TURBOPACK__imported__module__$5b$project$5d2f$clawd$2f$ai$2d$radio$2d$dj$2f$node_modules$2f$next$2f$dist$2f$compiled$2f$react$2f$jsx$2d$dev$2d$runtime$2e$js__$5b$app$2d$client$5d$__$28$ecmascript$29$__["jsxDEV"])(HomeContent, {}, void 0, false, {
            fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
            lineNumber: 397,
            columnNumber: 7
        }, this)
    }, void 0, false, {
        fileName: "[project]/clawd/ai-radio-dj/app/page.tsx",
        lineNumber: 396,
        columnNumber: 5
    }, this);
}
_c2 = Home;
var _c, _c1, _c2;
__turbopack_context__.k.register(_c, "AppleMusicDashboard");
__turbopack_context__.k.register(_c1, "HomeContent");
__turbopack_context__.k.register(_c2, "Home");
if (typeof globalThis.$RefreshHelpers$ === 'object' && globalThis.$RefreshHelpers !== null) {
    __turbopack_context__.k.registerExports(__turbopack_context__.m, globalThis.$RefreshHelpers$);
}
}),
]);

//# sourceMappingURL=clawd_ai-radio-dj_24b1cea3._.js.map