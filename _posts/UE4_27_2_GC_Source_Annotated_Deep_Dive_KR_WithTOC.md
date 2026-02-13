# Table of Contents


---

UE4.27.2-release Garbage Collection (GC)
소스코드 포함 · 함수별 주석형 심층 분석 문서

기준 소스: 사용자 제공 UE4.27.2-release tag 파일 묶음

문서 목적: GC 파이프라인(Entry→Mark→Sweep→Purge), 참조 추적(토큰 스트림/Serialize/AddReferencedObjects/FGCObject), 클러스터 GC, Incremental purge, UObject 수명주기를 실제 코드 조각과 함께 ‘함수 단위’로 해부하고, 왜 이런 구현을 선택했는지(성능/스레딩/안정성 트레이드오프)까지 설명한다.

메모: 엔진 소스는 Epic EULA 대상이지만, 이 문서는 사용자가 제공한 소스 파일에서 필요한 코드 조각을 인용·주석화하여 학습/내부 분석 목적의 문서로 구성한다.

생성 시각: 2026-02-12 23:15:53


목차

1. GC 개요와 설계 목표(UE4 철학)

2. GC 오케스트레이션: GarbageCollection.cpp

3. Reachability(마킹) 엔진: FastReferenceCollector.h

4. 참조 열거의 핵: 토큰 스트림과 Class.*

5. UObject 파괴 수명주기: Obj.cpp, UObjectBaseUtility.h

6. 전역 오브젝트 레지스트리: UObjectArray.*

7. Cluster GC: UObjectClusters.cpp

8. 비-UObject 참조 보고: GCObject.h

9. 해시/탐색과 GC 상호작용: UObjectHash.cpp

10. 실무 디버깅/성능 튜닝 체크리스트


1. GC 개요와 설계 목표(UE4.27.2 관점)

UE4의 GC는 전통적인 Mark & Sweep 계열이지만, 대규모 월드/에디터/블루프린트/핫리로드 등 동적 환경에서 ‘예측 가능한 수명 관리’와 ‘프레임 타임 안정성’을 달성하기 위해 다양한 최적화/안전장치를 결합한다.

1.1 UE4 GC가 풀어야 하는 제약 조건

UObject는 리플렉션/직렬화/에디터/네트워크/블루프린트와 연결되어, 단순 참조 카운팅만으로 수명을 결정하기 어렵다.

참조 그래프는 런타임에 동적으로 변하며, 컨테이너/스크립트/에디터 오브젝트까지 포함해 매우 크다.

GC 자체가 히치를 만들 수 있으므로, Mark/Destroy/Purge를 분산(Incremental)하거나, 클러스터로 비용을 줄여야 한다.

안정성: 잘못된 포인터/무효 객체를 안전하게 감지하고, 가능하면 디버그에서 조기 폭발(assert/log)시키며, Shipping에서는 비용을 최소화해야 한다.

1.2 핵심 용어(문서 전체에서 사용하는 의미)

Root(Seed): 참조 그래프 탐색 시작점. AddToRoot, 엔진 전역, 월드/레벨 루트, 클러스터 루트 등.

Reachable: 루트에서 참조를 따라가면 도달되는 객체. 이번 사이클에서 살아남는다.

Unreachable: 이번 마킹에서 도달되지 못한 객체. Sweep/Destroy/Purge 대상.

PendingKill: 게임 로직 관점에서 이미 파괴 예약된 상태(즉시 free 아님).

BeginDestroy/FinishDestroy: 파괴 수명주기의 단계(리소스 해제 → 최종 파괴).


2. GC 오케스트레이션: GarbageCollection.cpp

이 파일은 GC 전체를 지휘한다. ‘언제, 어떤 옵션으로, 어떤 단계를 어떤 순서로 실행할지’를 결정하며, Reachability 분석을 FastReferenceCollector로 위임하고, Destroy/Purge를 단계적으로 수행한다.

CollectGarbage()  —  GarbageCollection.cpp:2161-2171

역할: GC 전체 사이클의 상위 엔트리. 옵션/상태를 구성하고 Mark→Sweep→Purge를 트리거한다.

왜 이렇게 구현했나(설계 의도/트레이드오프):

‘정확성’과 ‘프레임 타임’을 동시에 달성하기 위해 단계(Reachability/Destroy/Purge)를 분리하고, 필요 시 점진 처리로 분산한다.

Async loading/월드 전환/리소스 해제와 충돌하지 않도록 사전 동기화·정리 훅을 둔다(안전성).

통계/스코프(프로파일링) 측정 지점을 두어, 프로젝트별 튜닝이 가능하게 한다.

코드(발췌):

```cpp
  2161  void CollectGarbage(EObjectFlags KeepFlags, bool bPerformFullPurge)
  2162  {
  2163  	// No other thread may be performing UObject operations while we're running
  2164  	AcquireGCLock();
  2165  
  2166  	// Perform actual garbage collection
  2167  	CollectGarbageInternal(KeepFlags, bPerformFullPurge);
  2168  
  2169  	// Other threads are free to use UObjects
  2170  	ReleaseGCLock();
  2171  }
```

주석형 해설(핵심 흐름):

입력 파라미터(KeepFlags/옵션)가 ‘어떤 오브젝트를 수거 대상에서 제외할지’를 결정한다.

GC는 보통 (1) 사전 동기화/정리 → (2) Reachability 분석 → (3) Unreachable 수집/Unhash → (4) Destroy 시작 → (5) Purge(완전 해제) 순으로 이어진다.

Mark는 ‘참조 열거 비용’이 핵심이므로, 이 단계는 FastReferenceCollector/토큰 스트림/클러스터로 가속된다.

Destroy/Purge는 ‘프레임 타임 안정성’을 위해 점진적 처리를 고려한다(시간 제한 기반).


PerformReachabilityAnalysis()  —  GarbageCollection.cpp:1325-1366

역할: Root(Seed)에서 시작해 도달 가능한 UObject를 마킹(Reachable)한다. 실제 참조 추적은 FastReferenceCollector 계열로 위임되는 경우가 많다.

왜 이렇게 구현했나(설계 의도/트레이드오프):

Reachability는 O(N + E) 그래프 탐색이므로, 참조 열거(E)를 토큰 스트림으로 선형화해 캐시 효율을 높인다.

병렬화/배치화를 위해 worklist 기반 처리/디스패처를 쓰는 구조가 유리하다.

코드(발췌):

```cpp
  1325  	void PerformReachabilityAnalysis(EObjectFlags KeepFlags, bool bForceSingleThreaded, bool bWithClusters)
  1326  	{
  1327  		LLM_SCOPE(ELLMTag::GC);
  1328  
  1329  		SCOPED_NAMED_EVENT(FRealtimeGC_PerformReachabilityAnalysis, FColor::Red);
  1330  		DECLARE_SCOPE_CYCLE_COUNTER(TEXT("FRealtimeGC::PerformReachabilityAnalysis"), STAT_FArchiveRealtimeGC_PerformReachabilityAnalysis, STATGROUP_GC);
  1331  
  1332  		/** Growing array of objects that require serialization */
  1333  		FGCArrayStruct* ArrayStruct = FGCArrayPool::Get().GetArrayStructFromPool();
  1334  		TArray<UObject*>& ObjectsToSerialize = ArrayStruct->ObjectsToSerialize;
  1335  
  1336  		// Reset object count.
  1337  		GObjectCountDuringLastMarkPhase.Reset();
  1338  
  1339  		// Make sure GC referencer object is checked for references to other objects even if it resides in permanent object pool
  1340  		if (FPlatformProperties::RequiresCookedData() && FGCObject::GGCObjectReferencer && GUObjectArray.IsDisregardForGC(FGCObject::GGCObjectReferencer))
  1341  		{
  1342  			ObjectsToSerialize.Add(FGCObject::GGCObjectReferencer);
  1343  		}
  1344  
  1345  		{
  1346  			const double StartTime = FPlatformTime::Seconds();
  1347  			(this->*MarkObjectsFunctions[GetGCFunctionIndex(!bForceSingleThreaded, bWithClusters)])(ObjectsToSerialize, KeepFlags);
  1348  			UE_LOG(LogGarbage, Verbose, TEXT("%f ms for MarkObjectsAsUnreachable Phase (%d Objects To Serialize)"), (FPlatformTime::Seconds() - StartTime) * 1000, ObjectsToSerialize.Num());
  1349  		}
  1350  
  1351  		{
  1352  			const double StartTime = FPlatformTime::Seconds();
  1353  			PerformReachabilityAnalysisOnObjects(ArrayStruct, bForceSingleThreaded, bWithClusters);
  1354  			UE_LOG(LogGarbage, Verbose, TEXT("%f ms for Reachability Analysis"), (FPlatformTime::Seconds() - StartTime) * 1000);
  1355  		}
  1356          
  1357  		// Allowing external systems to add object roots. This can't be done through AddReferencedObjects
  1358  		// because it may require tracing objects (via FGarbageCollectionTracer) multiple times
  1359  		FCoreUObjectDelegates::TraceExternalRootsForReachabilityAnalysis.Broadcast(*this, KeepFlags, bForceSingleThreaded);
  1360  
  1361  		FGCArrayPool::Get().ReturnToPool(ArrayStruct);
  1362  
  1363  #if UE_BUILD_DEBUG
  1364  		FGCArrayPool::Get().CheckLeaks();
  1365  #endif
  1366  	}
```

주석형 해설(핵심 흐름):

입력 파라미터(KeepFlags/옵션)가 ‘어떤 오브젝트를 수거 대상에서 제외할지’를 결정한다.

GC는 보통 (1) 사전 동기화/정리 → (2) Reachability 분석 → (3) Unreachable 수집/Unhash → (4) Destroy 시작 → (5) Purge(완전 해제) 순으로 이어진다.

Mark는 ‘참조 열거 비용’이 핵심이므로, 이 단계는 FastReferenceCollector/토큰 스트림/클러스터로 가속된다.

Destroy/Purge는 ‘프레임 타임 안정성’을 위해 점진적 처리를 고려한다(시간 제한 기반).


MarkObjectsAsUnreachable()  —  GarbageCollection.cpp:1135-1318

역할: 대상 객체들을 ‘기본적으로 Unreachable’ 상태로 초기화하거나, Mark 상태를 리셋하는 단계. 이후 Reachable을 찾아 표시한다.

왜 이렇게 구현했나(설계 의도/트레이드오프):

전역 배열(GUObjectArray)을 한 번 순회하며 플래그를 초기화하는 방식은 분기/캐시 관점에서 예측 가능성이 높다.

병렬 Reachability에서 ‘기본값 Unreachable’은 상태 전환(클리어)만으로 Reachable을 표현할 수 있어 경쟁을 줄일 수 있다.

코드(발췌):

```cpp
  1135  	void MarkObjectsAsUnreachable(TArray<UObject*>& ObjectsToSerialize, const EObjectFlags KeepFlags)
  1136  	{
  1137  		const EInternalObjectFlags FastKeepFlags = EInternalObjectFlags::GarbageCollectionKeepFlags;
  1138  		const int32 MaxNumberOfObjects = GUObjectArray.GetObjectArrayNum() - GUObjectArray.GetFirstGCIndex();
  1139  		const int32 NumThreads = FMath::Max(1, FTaskGraphInterface::Get().GetNumWorkerThreads());
  1140  		const int32 NumberOfObjectsPerThread = (MaxNumberOfObjects / NumThreads) + 1;		
  1141  
  1142  		TLockFreePointerListFIFO<FUObjectItem, PLATFORM_CACHE_LINE_SIZE> ClustersToDissolveList;
  1143  		TLockFreePointerListFIFO<FUObjectItem, PLATFORM_CACHE_LINE_SIZE> KeepClusterRefsList;
  1144  		FGCArrayStruct** ObjectsToSerializeArrays = new FGCArrayStruct*[NumThreads];
  1145  		for (int32 ThreadIndex = 0; ThreadIndex < NumThreads; ++ThreadIndex)
  1146  		{
  1147  			ObjectsToSerializeArrays[ThreadIndex] = FGCArrayPool::Get().GetArrayStructFromPool();
  1148  		}
  1149  
  1150  		// Iterate over all objects. Note that we iterate over the UObjectArray and usually check only internal flags which
  1151  		// are part of the array so we don't suffer from cache misses as much as we would if we were to check ObjectFlags.
  1152  		ParallelFor(NumThreads, [ObjectsToSerializeArrays, &ClustersToDissolveList, &KeepClusterRefsList, FastKeepFlags, KeepFlags, NumberOfObjectsPerThread, NumThreads, MaxNumberOfObjects](int32 ThreadIndex)
  1153  		{
  1154  			int32 FirstObjectIndex = ThreadIndex * NumberOfObjectsPerThread + GUObjectArray.GetFirstGCIndex();
  1155  			int32 NumObjects = (ThreadIndex < (NumThreads - 1)) ? NumberOfObjectsPerThread : (MaxNumberOfObjects - (NumThreads - 1) * NumberOfObjectsPerThread);
  1156  			int32 LastObjectIndex = FMath::Min(GUObjectArray.GetObjectArrayNum() - 1, FirstObjectIndex + NumObjects - 1);
  1157  			int32 ObjectCountDuringMarkPhase = 0;
  1158  			TArray<UObject*>& LocalObjectsToSerialize = ObjectsToSerializeArrays[ThreadIndex]->ObjectsToSerialize;
  1159  
  1160  			for (int32 ObjectIndex = FirstObjectIndex; ObjectIndex <= LastObjectIndex; ++ObjectIndex)
  1161  			{
  1162  				FUObjectItem* ObjectItem = &GUObjectArray.GetObjectItemArrayUnsafe()[ObjectIndex];
  1163  				if (ObjectItem->Object)
  1164  				{
  1165  					UObject* Object = (UObject*)ObjectItem->Object;
  1166  
  1167  					// We can't collect garbage during an async load operation and by now all unreachable objects should've been purged.
  1168  					checkf(!ObjectItem->HasAnyFlags(EInternalObjectFlags::Unreachable|EInternalObjectFlags::PendingConstruction), TEXT("%s"), *Object->GetFullName());
  1169  
  1170  					// Keep track of how many objects are around.
  1171  					ObjectCountDuringMarkPhase++;
  1172  					
  1173  					if (bWithClusters)
  1174  					{
  1175  						ObjectItem->ClearFlags(EInternalObjectFlags::ReachableInCluster);
  1176  					}
  1177  					// Special case handling for objects that are part of the root set.
  1178  					if (ObjectItem->IsRootSet())
  1179  					{
  1180  						// IsValidLowLevel is extremely slow in this loop so only do it in debug
  1181  						checkSlow(Object->IsValidLowLevel());
  1182  						// We cannot use RF_PendingKill on objects that are part of the root set.
  1183  #if DO_GUARD_SLOW
  1184  						checkCode(if (ObjectItem->IsPendingKill()) { UE_LOG(LogGarbage, Fatal, TEXT("Object %s is part of root set though has been marked RF_PendingKill!"), *Object->GetFullName()); });
  1185  #endif
  1186  						if (bWithClusters)
  1187  						{
  1188  							if (ObjectItem->HasAnyFlags(EInternalObjectFlags::ClusterRoot) || ObjectItem->GetOwnerIndex() > 0)
  1189  							{
  1190  								KeepClusterRefsList.Push(ObjectItem);
  1191  							}
  1192  						}
  1193  
  1194  						LocalObjectsToSerialize.Add(Object);
  1195  					}
  1196  					// Regular objects or cluster root objects
  1197  					else if (!bWithClusters || ObjectItem->GetOwnerIndex() <= 0)
  1198  					{
  1199  						bool bMarkAsUnreachable = true;
  1200  						// Internal flags are super fast to check and is used by async loading and must have higher precedence than PendingKill
  1201  						if (ObjectItem->HasAnyFlags(FastKeepFlags))
  1202  						{
  1203  							bMarkAsUnreachable = false;
  1204  						}
  1205  						// If KeepFlags is non zero this is going to be very slow due to cache misses
  1206  						else if (!ObjectItem->IsPendingKill() && KeepFlags != RF_NoFlags && Object->HasAnyFlags(KeepFlags))
  1207  						{
  1208  							bMarkAsUnreachable = false;
  1209  						}
  1210  						else if (ObjectItem->IsPendingKill() && bWithClusters && ObjectItem->HasAnyFlags(EInternalObjectFlags::ClusterRoot))
  1211  						{
  1212  							ClustersToDissolveList.Push(ObjectItem);
  1213  						}
  1214  
  1215  						// Mark objects as unreachable unless they have any of the passed in KeepFlags set and it's not marked for elimination..
  1216  						if (!bMarkAsUnreachable)
  1217  						{
  1218  							// IsValidLowLevel is extremely slow in this loop so only do it in debug
  1219  							checkSlow(Object->IsValidLowLevel());
  1220  							LocalObjectsToSerialize.Add(Object);
  1221  
  1222  							if (bWithClusters)
  1223  							{
  1224  								if (ObjectItem->HasAnyFlags(EInternalObjectFlags::ClusterRoot))
  1225  								{
  1226  									KeepClusterRefsList.Push(ObjectItem);
  1227  								}
  1228  							}
  1229  						}
  1230  						else
  1231  						{
  1232  							ObjectItem->SetFlags(EInternalObjectFlags::Unreachable);
  1233  						}
  1234  					}
  1235  					// Cluster objects 
  1236  					else if (bWithClusters && ObjectItem->GetOwnerIndex() > 0)
  1237  					{
  1238  						// treat cluster objects with FastKeepFlags the same way as if they are in the root set
  1239  						if (ObjectItem->HasAnyFlags(FastKeepFlags))
  1240  						{
  1241  							KeepClusterRefsList.Push(ObjectItem);
  1242  							LocalObjectsToSerialize.Add(Object);
  1243  						}
  1244  					}
  1245  				}
  1246  			}
  1247  
  1248  			GObjectCountDuringLastMarkPhase.Add(ObjectCountDuringMarkPhase);
  1249  		}, !bParallel);
  1250  		
  1251  		// Collect all objects to serialize from all threads and put them into a single array
  1252  		{
  1253  			int32 NumObjectsToSerialize = 0;
  1254  			for (int32 ThreadIndex = 0; ThreadIndex < NumThreads; ++ThreadIndex)
  1255  			{
  1256  				NumObjectsToSerialize += ObjectsToSerializeArrays[ThreadIndex]->ObjectsToSerialize.Num();
  1257  			}
  1258  			ObjectsToSerialize.Reserve(NumObjectsToSerialize);
  1259  			for (int32 ThreadIndex = 0; ThreadIndex < NumThreads; ++ThreadIndex)
  1260  			{
  1261  				ObjectsToSerialize.Append(ObjectsToSerializeArrays[ThreadIndex]->ObjectsToSerialize);
  1262  				FGCArrayPool::Get().ReturnToPool(ObjectsToSerializeArrays[ThreadIndex]);
  1263  			}
  1264  			delete[] ObjectsToSerializeArrays;
  1265  		}
  1266  
  1267  		if (bWithClusters)
  1268  		{
  1269  			TArray<FUObjectItem*> ClustersToDissolve;
  1270  			ClustersToDissolveList.PopAll(ClustersToDissolve);
  1271  			for (FUObjectItem* ObjectItem : ClustersToDissolve)
  1272  			{
  1273  				// Check if the object is still a cluster root - it's possible one of the previous
  1274  				// DissolveClusterAndMarkObjectsAsUnreachable calls already dissolved its cluster
  1275  				if (ObjectItem->HasAnyFlags(EInternalObjectFlags::ClusterRoot))
  1276  				{
  1277  					GUObjectClusters.DissolveClusterAndMarkObjectsAsUnreachable(ObjectItem);
  1278  					GUObjectClusters.SetClustersNeedDissolving();
  1279  				}
  1280  			}
  1281  		}
  1282  
  1283  		if (bWithClusters)
  1284  		{
  1285  			TArray<FUObjectItem*> KeepClusterRefs;
  1286  			KeepClusterRefsList.PopAll(KeepClusterRefs);
  1287  			for (FUObjectItem* ObjectItem : KeepClusterRefs)
  1288  			{
  1289  				if (ObjectItem->GetOwnerIndex() > 0)
  1290  				{
  1291  					checkSlow(!ObjectItem->HasAnyFlags(EInternalObjectFlags::ClusterRoot));
  1292  					bool bNeedsDoing = !ObjectItem->HasAnyFlags(EInternalObjectFlags::ReachableInCluster);
  1293  					if (bNeedsDoing)
  1294  					{
  1295  						ObjectItem->SetFlags(EInternalObjectFlags::ReachableInCluster);
  1296  						// Make sure cluster root object is reachable too
  1297  						const int32 OwnerIndex = ObjectItem->GetOwnerIndex();
  1298  						FUObjectItem* RootObjectItem = GUObjectArray.IndexToObjectUnsafeForGC(OwnerIndex);
  1299  						checkSlow(RootObjectItem->HasAnyFlags(EInternalObjectFlags::ClusterRoot));
  1300  						// if it is reachable via keep flags we will do this below (or maybe already have)
  1301  						if (RootObjectItem->IsUnreachable()) 
  1302  						{
  1303  							RootObjectItem->ClearFlags(EInternalObjectFlags::Unreachable);
  1304  							// Make sure all referenced clusters are marked as reachable too
  1305  							FGCReferenceProcessor<EFastReferenceCollectorOptions::WithClusters>::MarkReferencedClustersAsReachable(RootObjectItem->GetClusterIndex(), ObjectsToSerialize);
  1306  						}
  1307  					}
  1308  				}
  1309  				else
  1310  				{
  1311  					checkSlow(ObjectItem->HasAnyFlags(EInternalObjectFlags::ClusterRoot));
  1312  					// this thing is definitely not marked unreachable, so don't test it here
  1313  					// Make sure all referenced clusters are marked as reachable too
  1314  					FGCReferenceProcessor<EFastReferenceCollectorOptions::WithClusters>::MarkReferencedClustersAsReachable(ObjectItem->GetClusterIndex(), ObjectsToSerialize);
  1315  				}
  1316  			}
  1317  		}
  1318  	}
```

주석형 해설(핵심 흐름):

입력 파라미터(KeepFlags/옵션)가 ‘어떤 오브젝트를 수거 대상에서 제외할지’를 결정한다.

GC는 보통 (1) 사전 동기화/정리 → (2) Reachability 분석 → (3) Unreachable 수집/Unhash → (4) Destroy 시작 → (5) Purge(완전 해제) 순으로 이어진다.

Mark는 ‘참조 열거 비용’이 핵심이므로, 이 단계는 FastReferenceCollector/토큰 스트림/클러스터로 가속된다.

Destroy/Purge는 ‘프레임 타임 안정성’을 위해 점진적 처리를 고려한다(시간 제한 기반).


GatherUnreachableObjects()  —  GarbageCollection.cpp:1853-1932

역할: Reachability 결과를 바탕으로 실제로 정리할(Unreachable) 객체 목록을 수집한다.

왜 이렇게 구현했나(설계 의도/트레이드오프):

Unreachable 목록을 명시적으로 만들어 두면 이후 Destroy/Purge 단계에서 ‘배치 처리’와 ‘시간 제한 분산’이 쉬워진다.

디버그/검증 시 어떤 객체가 왜 수거 대상인지 기록/로그를 남기기 쉽다.

코드(발췌):

```cpp
  1853  void GatherUnreachableObjects(bool bForceSingleThreaded)
  1854  {
  1855  	DECLARE_SCOPE_CYCLE_COUNTER(TEXT("CollectGarbageInternal.GatherUnreachableObjects"), STAT_CollectGarbageInternal_GatherUnreachableObjects, STATGROUP_GC);
  1856  
  1857  	const double StartTime = FPlatformTime::Seconds();
  1858  
  1859  	GUnreachableObjects.Reset();
  1860  	GUnrechableObjectIndex = 0;
  1861  
  1862  	int32 MaxNumberOfObjects = GUObjectArray.GetObjectArrayNum() - (GExitPurge ? 0 : GUObjectArray.GetFirstGCIndex());
  1863  	int32 NumThreads = FMath::Max(1, FTaskGraphInterface::Get().GetNumWorkerThreads());
  1864  	int32 NumberOfObjectsPerThread = (MaxNumberOfObjects / NumThreads) + 1;
  1865  
  1866  	TArray<FUObjectItem*> ClusterItemsToDestroy;
  1867  	int32 ClusterObjects = 0;
  1868  
  1869  	// Iterate over all objects. Note that we iterate over the UObjectArray and usually check only internal flags which
  1870  	// are part of the array so we don't suffer from cache misses as much as we would if we were to check ObjectFlags.
  1871  	ParallelFor(NumThreads, [&ClusterItemsToDestroy, NumberOfObjectsPerThread, NumThreads, MaxNumberOfObjects](int32 ThreadIndex)
  1872  	{
  1873  		int32 FirstObjectIndex = ThreadIndex * NumberOfObjectsPerThread + (GExitPurge ? 0 : GUObjectArray.GetFirstGCIndex());
  1874  		int32 NumObjects = (ThreadIndex < (NumThreads - 1)) ? NumberOfObjectsPerThread : (MaxNumberOfObjects - (NumThreads - 1) * NumberOfObjectsPerThread);
  1875  		int32 LastObjectIndex = FMath::Min(GUObjectArray.GetObjectArrayNum() - 1, FirstObjectIndex + NumObjects - 1);
  1876  		TArray<FUObjectItem*> ThisThreadUnreachableObjects;
  1877  		TArray<FUObjectItem*> ThisThreadClusterItemsToDestroy;
  1878  
  1879  		for (int32 ObjectIndex = FirstObjectIndex; ObjectIndex <= LastObjectIndex; ++ObjectIndex)
  1880  		{
  1881  			FUObjectItem* ObjectItem = &GUObjectArray.GetObjectItemArrayUnsafe()[ObjectIndex];
  1882  			if (ObjectItem->IsUnreachable())
  1883  			{
  1884  				ThisThreadUnreachableObjects.Add(ObjectItem);
  1885  				if (ObjectItem->HasAnyFlags(EInternalObjectFlags::ClusterRoot))
  1886  				{
  1887  					// We can't mark cluster objects as unreachable here as they may be currently being processed on another thread
  1888  					ThisThreadClusterItemsToDestroy.Add(ObjectItem);
  1889  				}
  1890  			}
  1891  		}
  1892  		if (ThisThreadUnreachableObjects.Num())
  1893  		{
  1894  			FScopeLock UnreachableObjectsLock(&GUnreachableObjectsCritical);
  1895  			GUnreachableObjects.Append(ThisThreadUnreachableObjects);
  1896  			ClusterItemsToDestroy.Append(ThisThreadClusterItemsToDestroy);
  1897  		}
  1898  	}, bForceSingleThreaded);
  1899  
  1900  	{
  1901  		// @todo: if GUObjectClusters.FreeCluster() was thread safe we could do this in parallel too
  1902  		for (FUObjectItem* ClusterRootItem : ClusterItemsToDestroy)
  1903  		{
  1904  #if UE_GCCLUSTER_VERBOSE_LOGGING
  1905  			UE_LOG(LogGarbage, Log, TEXT("Destroying cluster (%d) %s"), ClusterRootItem->GetClusterIndex(), *static_cast<UObject*>(ClusterRootItem->Object)->GetFullName());
  1906  #endif
  1907  			ClusterRootItem->ClearFlags(EInternalObjectFlags::ClusterRoot);
  1908  
  1909  			const int32 ClusterIndex = ClusterRootItem->GetClusterIndex();
  1910  			FUObjectCluster& Cluster = GUObjectClusters[ClusterIndex];
  1911  			for (int32 ClusterObjectIndex : Cluster.Objects)
  1912  			{
  1913  				FUObjectItem* ClusterObjectItem = GUObjectArray.IndexToObjectUnsafeForGC(ClusterObjectIndex);
  1914  				ClusterObjectItem->SetOwnerIndex(0);
  1915  
  1916  				if (!ClusterObjectItem->HasAnyFlags(EInternalObjectFlags::ReachableInCluster))
  1917  				{
  1918  					ClusterObjectItem->SetFlags(EInternalObjectFlags::Unreachable);
  1919  					ClusterObjects++;
  1920  					GUnreachableObjects.Add(ClusterObjectItem);
  1921  				}
  1922  			}
  1923  			GUObjectClusters.FreeCluster(ClusterIndex);
  1924  		}
  1925  	}
  1926  
  1927  	UE_LOG(LogGarbage, Log, TEXT("%f ms for Gather Unreachable Objects (%d objects collected including %d cluster objects from %d clusters)"),
  1928  		(FPlatformTime::Seconds() - StartTime) * 1000,
  1929  		GUnreachableObjects.Num(),
  1930  		ClusterObjects,
  1931  		ClusterItemsToDestroy.Num());
  1932  }
```

주석형 해설(핵심 흐름):

입력 파라미터(KeepFlags/옵션)가 ‘어떤 오브젝트를 수거 대상에서 제외할지’를 결정한다.

GC는 보통 (1) 사전 동기화/정리 → (2) Reachability 분석 → (3) Unreachable 수집/Unhash → (4) Destroy 시작 → (5) Purge(완전 해제) 순으로 이어진다.

Mark는 ‘참조 열거 비용’이 핵심이므로, 이 단계는 FastReferenceCollector/토큰 스트림/클러스터로 가속된다.

Destroy/Purge는 ‘프레임 타임 안정성’을 위해 점진적 처리를 고려한다(시간 제한 기반).


UnhashUnreachableObjects()  —  GarbageCollection.cpp:2098-2159

역할: Unreachable 객체들을 UObject 해시/검색 구조에서 제거한다(이후 검색/탐색에서 배제).

왜 이렇게 구현했나(설계 의도/트레이드오프):

수거 대상이 검색 시스템에 남아 있으면, 시스템이 무효 객체를 다시 잡는 위험이 커진다(안전성).

해시 제거를 먼저 하면 이후 단계에서 ‘동시에 참조되는’ 상황을 줄일 수 있다(무효 접근 방지).

코드(발췌):

```cpp
  2098  bool UnhashUnreachableObjects(bool bUseTimeLimit, float TimeLimit)
  2099  {
  2100  	DECLARE_SCOPE_CYCLE_COUNTER(TEXT("UnhashUnreachableObjects"), STAT_UnhashUnreachableObjects, STATGROUP_GC);
  2101  
  2102  	TGuardValue<bool> GuardObjUnhashUnreachableIsInProgress(GObjUnhashUnreachableIsInProgress, true);
  2103  
  2104  	FCoreUObjectDelegates::PreGarbageCollectConditionalBeginDestroy.Broadcast();
  2105  
  2106  	// Unhash all unreachable objects.
  2107  	const double StartTime = FPlatformTime::Seconds();
  2108  	const int32 TimeLimitEnforcementGranularityForBeginDestroy = 10;
  2109  	int32 Items = 0;
  2110  	int32 TimePollCounter = 0;
  2111  	const bool bFirstIteration = (GUnrechableObjectIndex == 0);
  2112  
  2113  	while (GUnrechableObjectIndex < GUnreachableObjects.Num())
  2114  	{
  2115  		//@todo UE4 - A prefetch was removed here. Re-add it. It wasn't right anyway, since it was ten items ahead and the consoles on have 8 prefetch slots
  2116  
  2117  		FUObjectItem* ObjectItem = GUnreachableObjects[GUnrechableObjectIndex++];
  2118  		{
  2119  			UObject* Object = static_cast<UObject*>(ObjectItem->Object);
  2120  			FScopedCBDProfile Profile(Object);
  2121  			// Begin the object's asynchronous destruction.
  2122  			Object->ConditionalBeginDestroy();
  2123  		}
  2124  
  2125  		Items++;
  2126  
  2127  		const bool bPollTimeLimit = ((TimePollCounter++) % TimeLimitEnforcementGranularityForBeginDestroy == 0);
  2128  		if (bUseTimeLimit && bPollTimeLimit && ((FPlatformTime::Seconds() - StartTime) > TimeLimit))
  2129  		{
  2130  			break;
  2131  		}
  2132  	}
  2133  
  2134  	const bool bTimeLimitReached = (GUnrechableObjectIndex < GUnreachableObjects.Num());
  2135  
  2136  	if (!bUseTimeLimit)
  2137  	{
  2138  		UE_LOG(LogGarbage, Log, TEXT("%f ms for %sunhashing unreachable objects (%d objects unhashed)"),
  2139  		(FPlatformTime::Seconds() - StartTime) * 1000,
  2140  		bUseTimeLimit ? TEXT("incrementally ") : TEXT(""),
  2141  			Items,
  2142  		GUnrechableObjectIndex, GUnreachableObjects.Num());
  2143  	}
  2144  	else if (!bTimeLimitReached)
  2145  	{
  2146  		// When doing incremental unhashing log only the first and last iteration (this was the last one)
  2147  		UE_LOG(LogGarbage, Log, TEXT("Finished unhashing unreachable objects (%d objects unhashed)."), GUnreachableObjects.Num());
  2148  	}
  2149  	else if (bFirstIteration)
  2150  	{
  2151  		// When doing incremental unhashing log only the first and last iteration (this was the first one)
  2152  		UE_LOG(LogGarbage, Log, TEXT("Starting unhashing unreachable objects (%d objects to unhash)."), GUnreachableObjects.Num());
  2153  	}
  2154  
  2155  	FCoreUObjectDelegates::PostGarbageCollectConditionalBeginDestroy.Broadcast();
  2156  
  2157  	// Return true if time limit has been reached
  2158  	return bTimeLimitReached;
  2159  }
```

주석형 해설(핵심 흐름):

입력 파라미터(KeepFlags/옵션)가 ‘어떤 오브젝트를 수거 대상에서 제외할지’를 결정한다.

GC는 보통 (1) 사전 동기화/정리 → (2) Reachability 분석 → (3) Unreachable 수집/Unhash → (4) Destroy 시작 → (5) Purge(완전 해제) 순으로 이어진다.

Mark는 ‘참조 열거 비용’이 핵심이므로, 이 단계는 FastReferenceCollector/토큰 스트림/클러스터로 가속된다.

Destroy/Purge는 ‘프레임 타임 안정성’을 위해 점진적 처리를 고려한다(시간 제한 기반).


IncrementalPurgeGarbage()  —  GarbageCollection.cpp:1446-1515

역할: Destroy가 끝났거나 파괴 준비가 된 객체들을 실제로 메모리 반환까지 진행한다. 시간 제한(time-slice)에 따라 여러 프레임에 분산될 수 있다.

왜 이렇게 구현했나(설계 의도/트레이드오프):

한 프레임에 수천~수만 UObject를 Purge하면 히치가 크므로, 시간 제한 기반 incremental 처리가 프레임 안정성을 높인다.

리소스 해제(렌더/GPU 등)는 즉시 끝나지 않을 수 있어 ‘ReadyToFinish’ 체크 기반 단계 진행이 필요하다.

코드(발췌):

```cpp
  1446  void IncrementalPurgeGarbage(bool bUseTimeLimit, float TimeLimit)
  1447  {
  1448  #if !UE_WITH_GC
  1449  	return;
  1450  #else
  1451  	SCOPED_NAMED_EVENT(IncrementalPurgeGarbage, FColor::Red);
  1452  	DECLARE_SCOPE_CYCLE_COUNTER(TEXT("IncrementalPurgeGarbage"), STAT_IncrementalPurgeGarbage, STATGROUP_GC);
  1453  	CSV_SCOPED_TIMING_STAT_EXCLUSIVE(GarbageCollection);
  1454  
  1455  	if (GExitPurge)
  1456  	{
  1457  		GObjPurgeIsRequired = true;
  1458  		GUObjectArray.DisableDisregardForGC();
  1459  		GObjCurrentPurgeObjectIndexNeedsReset = true;
  1460  	}
  1461  	// Early out if there is nothing to do.
  1462  	if (!GObjPurgeIsRequired)
  1463  	{
  1464  		return;
  1465  	}
  1466  
  1467  	bool bCompleted = false;
  1468  
  1469  	struct FResetPurgeProgress
  1470  	{
  1471  		bool& bCompletedRef;
  1472  		FResetPurgeProgress(bool& bInCompletedRef)
  1473  			: bCompletedRef(bInCompletedRef)
  1474  		{
  1475  			// Incremental purge is now in progress.
  1476  			GObjIncrementalPurgeIsInProgress = true;
  1477  			FPlatformMisc::MemoryBarrier();
  1478  		}
  1479  		~FResetPurgeProgress()
  1480  		{
  1481  			if (bCompletedRef)
  1482  			{
  1483  				GObjIncrementalPurgeIsInProgress = false;
  1484  				FPlatformMisc::MemoryBarrier();
  1485  			}
  1486  		}
  1487  
  1488  	} ResetPurgeProgress(bCompleted);
  1489  	
  1490  	{
  1491  		// Lock before settting GCStartTime as it could be slow to lock if async loading is in progress
  1492  		// but we still want to perform some GC work otherwise we'd be keeping objects in memory for a long time
  1493  		FConditionalGCLock ScopedGCLock;
  1494  
  1495  		// Keep track of start time to enforce time limit unless bForceFullPurge is true;
  1496  		GCStartTime = FPlatformTime::Seconds();
  1497  		bool bTimeLimitReached = false;
  1498  
  1499  		if (GUnrechableObjectIndex < GUnreachableObjects.Num())
  1500  		{
  1501  			bTimeLimitReached = UnhashUnreachableObjects(bUseTimeLimit, TimeLimit);
  1502  
  1503  			if (GUnrechableObjectIndex >= GUnreachableObjects.Num())
  1504  			{
  1505  				FScopedCBDProfile::DumpProfile();
  1506  			}
  1507  		}
  1508  
  1509  		if (!bTimeLimitReached)
  1510  		{
  1511  			bCompleted = IncrementalDestroyGarbage(bUseTimeLimit, TimeLimit);
  1512  		}
  1513  	}
  1514  #endif // !UE_WITH_GC
  1515  }
```

주석형 해설(핵심 흐름):

입력 파라미터(KeepFlags/옵션)가 ‘어떤 오브젝트를 수거 대상에서 제외할지’를 결정한다.

GC는 보통 (1) 사전 동기화/정리 → (2) Reachability 분석 → (3) Unreachable 수집/Unhash → (4) Destroy 시작 → (5) Purge(완전 해제) 순으로 이어진다.

Mark는 ‘참조 열거 비용’이 핵심이므로, 이 단계는 FastReferenceCollector/토큰 스트림/클러스터로 가속된다.

Destroy/Purge는 ‘프레임 타임 안정성’을 위해 점진적 처리를 고려한다(시간 제한 기반).



3. Reachability(마킹) 엔진: FastReferenceCollector.h

FastReferenceCollector는 GC의 ‘핵심 비용’을 줄이는 장치다. 중요한 점은: UE가 참조를 찾는 방식을 ‘토큰 스트림(선형 스캔)’로 바꾸고, 그 결과를 배치/병렬 처리하기 좋게 구조화했다는 것이다.

3.1 파일에서 핵심적으로 볼 것(독서 지침)

Collector(수집 루프)와 Processor(참조 처리 정책)의 분리: 재사용성과 모드(검증/RTGC 등) 확장성

Work queue / batch dispatcher / chunk 처리: 락 경쟁을 줄이고 워커 스레드를 활용하는 구조

Reference visiting의 inlining/템플릿화: 분기/가상 호출 비용을 낮추는 선택

핵심 코드 주변: 'TFastReferenceCollector'  —  FastReferenceCollector.h:216~

코드(발췌):

```cpp
   216  
   217  #if UE_BUILD_DEBUG
   218  	void CheckLeaks()
   219  	{
   220  		// This function is called after GC has finished so at this point there should be no
   221  		// arrays used by GC and all should be returned to the pool
   222  		const int32 LeakedGCPoolArrays = NumberOfUsedArrays.GetValue();
   223  		checkSlow(LeakedGCPoolArrays == 0);
   224  	}
   225  #endif
   226  
   227  private:
   228  
   229  	/** Holds the collection of recycled arrays. */
   230  	TLockFreePointerListLIFO< FGCArrayStruct > Pool;
   231  
   232  #if UE_BUILD_DEBUG
   233  	/** Number of arrays currently acquired from the pool by GC */
   234  	FThreadSafeCounter NumberOfUsedArrays;
   235  #endif // UE_BUILD_DEBUG
   236  };
   237  
   238  /**
   239   * Helper class that looks for UObject references by traversing UClass token stream and calls AddReferencedObjects.
   240   * Provides a generic way of processing references that is used by Unreal Engine garbage collection.
   241   * Can be used for fast (does not use serialization) reference collection purposes.
   242   * 
   243   * IT IS CRITICAL THIS CLASS DOES NOT CHANGE WITHOUT CONSIDERING PERFORMANCE IMPACT OF SAID CHANGES
   244   *
   245   * This class depends on three components: ReferenceProcessor, ReferenceCollector and ArrayPool.
   246   * The assumptions for each of those components are as follows:
   247   *
   248     class FSampleReferenceProcessor
   249     {
   250     public:
   251       int32 GetMinDesiredObjectsPerSubTask() const;
   252  		 void HandleTokenStreamObjectReference(TArray<UObject*>& ObjectsToSerialize, UObject* ReferencingObject, UObject*& Object, const int32 TokenIndex, bool bAllowReferenceElimination);
   253  		 void UpdateDetailedStats(UObject* CurrentObject, uint32 DeltaCycles);
   254  		 void LogDetailedStatsSummary();
   255  	 };
   256  
   257  	 class FSampleCollector : public FReferenceCollector 
   258  	 {
   259  	   // Needs to implement FReferenceCollector pure virtual functions
   260  	 };
   261     
   262  	 class FSampleArrayPool
   263  	 {
   264  	   static FSampleArrayPool& Get();
   265  		 FGCArrayStruct* GetArrayStryctFromPool();
   266  		 void ReturnToPool(FGCArrayStruct* ArrayStruct);
   267  	 };
   268   */
   269  
   270  template <typename ReferenceProcessorType, typename CollectorType, typename ArrayPoolType, EFastReferenceCollectorOptions Options = EFastReferenceCollectorOptions::None>
   271  class TFastReferenceCollector
   272  {
   273  private:
   274  
   275  	constexpr FORCEINLINE bool IsParallel() const
   276  	{
   277  		return !!(Options & EFastReferenceCollectorOptions::Parallel);
   278  	}
   279  	constexpr FORCEINLINE bool CanAutogenerateTokenStream() const
   280  	{
   281  		return !!(Options & EFastReferenceCollectorOptions::AutogenerateTokenStream);
   282  	}
   283  	constexpr FORCEINLINE bool ShouldProcessNoOpTokens() const
   284  	{
   285  		return !!(Options & EFastReferenceCollectorOptions::ProcessNoOpTokens);
   286  	}
   287  	constexpr FORCEINLINE bool ShouldProcessWeakReferences() const
   288  	{
   289  		return !!(Options & EFastReferenceCollectorOptions::ProcessWeakReferences);
   290  	}
   291  	
   292  	class FCollectorTaskQueue
   293  	{
   294  		TFastReferenceCollector*	Owner;
   295  		ArrayPoolType& ArrayPool;
   296  		TLockFreePointerListUnordered<FGCArrayStruct, PLATFORM_CACHE_LINE_SIZE> Tasks;
   297  
   298  		FCriticalSection WaitingThreadsLock;
   299  		TArray<FEvent*> WaitingThreads;
   300  		bool bDone;
   301  		int32 NumThreadsStarted;
   302  	public:
   303  
   304  		FCollectorTaskQueue(TFastReferenceCollector* InOwner, ArrayPoolType& InArrayPool)
   305  			: Owner(InOwner)
   306  			, ArrayPool(InArrayPool)
   307  			, bDone(false)
   308  			, NumThreadsStarted(0)
   309  		{
   310  		}
   311  
   312  		void CheckDone()
   313  		{
   314  			FScopeLock Lock(&WaitingThreadsLock);
   315  			check(bDone);
   316  			check(!Tasks.Pop());
   317  			check(!WaitingThreads.Num());
   318  			check(NumThreadsStarted);
   319  		}
   320  
   321  		FORCENOINLINE void AddTask(const TArray<UObject*>* InObjectsToSerialize, int32 StartIndex, int32 NumObjects)
   322  		{
   323  			FGCArrayStruct* ArrayStruct = ArrayPool.GetArrayStructFromPool();
   324  			ArrayStruct->ObjectsToSerialize.AddUninitialized(NumObjects);
   325  			FMemory::Memcpy(ArrayStruct->ObjectsToSerialize.GetData(), InObjectsToSerialize->GetData() + StartIndex, NumObjects * sizeof(UObject*));
```

해설:

이 구간은 GC가 대량의 객체 참조를 어떻게 ‘빠르게’ 방문하는지 보여준다.

템플릿/인라인 기반 설계는 가상 호출/분기 비용을 줄여 대규모 반복에서 성능 이점을 얻는다.

배치/큐 구조가 보이면: 병렬 워커 스레드로 작업을 쪼개 락 경쟁을 줄이려는 의도다.

Processor가 분리되어 있으면: 동일한 수집 루프를 여러 모드(예: 검증 포함/미포함)로 재사용하기 위함이다.


핵심 코드 주변: 'FReferenceCollector'  —  FastReferenceCollector.h:202~

코드(발췌):

```cpp
   202  			}
   203  			ArrayStruct->WeakReferences.Reset();
   204  			if (bClearPools 
   205  				|| Index % 7 == 3) // delete 1/7th of them just to keep things from growing too much between full purges
   206  			{
   207  				delete ArrayStruct;
   208  			}
   209  			else
   210  			{
   211  				Pool.Push(ArrayStruct);
   212  			}
   213  			Index++;
   214  		}
   215  	}
   216  
   217  #if UE_BUILD_DEBUG
   218  	void CheckLeaks()
   219  	{
   220  		// This function is called after GC has finished so at this point there should be no
   221  		// arrays used by GC and all should be returned to the pool
   222  		const int32 LeakedGCPoolArrays = NumberOfUsedArrays.GetValue();
   223  		checkSlow(LeakedGCPoolArrays == 0);
   224  	}
   225  #endif
   226  
   227  private:
   228  
   229  	/** Holds the collection of recycled arrays. */
   230  	TLockFreePointerListLIFO< FGCArrayStruct > Pool;
   231  
   232  #if UE_BUILD_DEBUG
   233  	/** Number of arrays currently acquired from the pool by GC */
   234  	FThreadSafeCounter NumberOfUsedArrays;
   235  #endif // UE_BUILD_DEBUG
   236  };
   237  
   238  /**
   239   * Helper class that looks for UObject references by traversing UClass token stream and calls AddReferencedObjects.
   240   * Provides a generic way of processing references that is used by Unreal Engine garbage collection.
   241   * Can be used for fast (does not use serialization) reference collection purposes.
   242   * 
   243   * IT IS CRITICAL THIS CLASS DOES NOT CHANGE WITHOUT CONSIDERING PERFORMANCE IMPACT OF SAID CHANGES
   244   *
   245   * This class depends on three components: ReferenceProcessor, ReferenceCollector and ArrayPool.
   246   * The assumptions for each of those components are as follows:
   247   *
   248     class FSampleReferenceProcessor
   249     {
   250     public:
   251       int32 GetMinDesiredObjectsPerSubTask() const;
   252  		 void HandleTokenStreamObjectReference(TArray<UObject*>& ObjectsToSerialize, UObject* ReferencingObject, UObject*& Object, const int32 TokenIndex, bool bAllowReferenceElimination);
   253  		 void UpdateDetailedStats(UObject* CurrentObject, uint32 DeltaCycles);
   254  		 void LogDetailedStatsSummary();
   255  	 };
   256  
   257  	 class FSampleCollector : public FReferenceCollector 
   258  	 {
   259  	   // Needs to implement FReferenceCollector pure virtual functions
   260  	 };
   261     
   262  	 class FSampleArrayPool
   263  	 {
   264  	   static FSampleArrayPool& Get();
   265  		 FGCArrayStruct* GetArrayStryctFromPool();
   266  		 void ReturnToPool(FGCArrayStruct* ArrayStruct);
   267  	 };
   268   */
   269  
   270  template <typename ReferenceProcessorType, typename CollectorType, typename ArrayPoolType, EFastReferenceCollectorOptions Options = EFastReferenceCollectorOptions::None>
   271  class TFastReferenceCollector
   272  {
   273  private:
   274  
   275  	constexpr FORCEINLINE bool IsParallel() const
   276  	{
   277  		return !!(Options & EFastReferenceCollectorOptions::Parallel);
   278  	}
   279  	constexpr FORCEINLINE bool CanAutogenerateTokenStream() const
   280  	{
   281  		return !!(Options & EFastReferenceCollectorOptions::AutogenerateTokenStream);
   282  	}
   283  	constexpr FORCEINLINE bool ShouldProcessNoOpTokens() const
   284  	{
   285  		return !!(Options & EFastReferenceCollectorOptions::ProcessNoOpTokens);
   286  	}
   287  	constexpr FORCEINLINE bool ShouldProcessWeakReferences() const
   288  	{
   289  		return !!(Options & EFastReferenceCollectorOptions::ProcessWeakReferences);
   290  	}
   291  	
   292  	class FCollectorTaskQueue
   293  	{
   294  		TFastReferenceCollector*	Owner;
   295  		ArrayPoolType& ArrayPool;
   296  		TLockFreePointerListUnordered<FGCArrayStruct, PLATFORM_CACHE_LINE_SIZE> Tasks;
   297  
   298  		FCriticalSection WaitingThreadsLock;
   299  		TArray<FEvent*> WaitingThreads;
   300  		bool bDone;
   301  		int32 NumThreadsStarted;
   302  	public:
   303  
   304  		FCollectorTaskQueue(TFastReferenceCollector* InOwner, ArrayPoolType& InArrayPool)
   305  			: Owner(InOwner)
   306  			, ArrayPool(InArrayPool)
   307  			, bDone(false)
   308  			, NumThreadsStarted(0)
   309  		{
   310  		}
```

해설:

이 구간은 GC가 대량의 객체 참조를 어떻게 ‘빠르게’ 방문하는지 보여준다.

템플릿/인라인 기반 설계는 가상 호출/분기 비용을 줄여 대규모 반복에서 성능 이점을 얻는다.

배치/큐 구조가 보이면: 병렬 워커 스레드로 작업을 쪼개 락 경쟁을 줄이려는 의도다.

Processor가 분리되어 있으면: 동일한 수집 루프를 여러 모드(예: 검증 포함/미포함)로 재사용하기 위함이다.


핵심 코드 주변: 'FCollectorTask'  —  FastReferenceCollector.h:237~

코드(발췌):

```cpp
   237  
   238  /**
   239   * Helper class that looks for UObject references by traversing UClass token stream and calls AddReferencedObjects.
   240   * Provides a generic way of processing references that is used by Unreal Engine garbage collection.
   241   * Can be used for fast (does not use serialization) reference collection purposes.
   242   * 
   243   * IT IS CRITICAL THIS CLASS DOES NOT CHANGE WITHOUT CONSIDERING PERFORMANCE IMPACT OF SAID CHANGES
   244   *
   245   * This class depends on three components: ReferenceProcessor, ReferenceCollector and ArrayPool.
   246   * The assumptions for each of those components are as follows:
   247   *
   248     class FSampleReferenceProcessor
   249     {
   250     public:
   251       int32 GetMinDesiredObjectsPerSubTask() const;
   252  		 void HandleTokenStreamObjectReference(TArray<UObject*>& ObjectsToSerialize, UObject* ReferencingObject, UObject*& Object, const int32 TokenIndex, bool bAllowReferenceElimination);
   253  		 void UpdateDetailedStats(UObject* CurrentObject, uint32 DeltaCycles);
   254  		 void LogDetailedStatsSummary();
   255  	 };
   256  
   257  	 class FSampleCollector : public FReferenceCollector 
   258  	 {
   259  	   // Needs to implement FReferenceCollector pure virtual functions
   260  	 };
   261     
   262  	 class FSampleArrayPool
   263  	 {
   264  	   static FSampleArrayPool& Get();
   265  		 FGCArrayStruct* GetArrayStryctFromPool();
   266  		 void ReturnToPool(FGCArrayStruct* ArrayStruct);
   267  	 };
   268   */
   269  
   270  template <typename ReferenceProcessorType, typename CollectorType, typename ArrayPoolType, EFastReferenceCollectorOptions Options = EFastReferenceCollectorOptions::None>
   271  class TFastReferenceCollector
   272  {
   273  private:
   274  
   275  	constexpr FORCEINLINE bool IsParallel() const
   276  	{
   277  		return !!(Options & EFastReferenceCollectorOptions::Parallel);
   278  	}
   279  	constexpr FORCEINLINE bool CanAutogenerateTokenStream() const
   280  	{
   281  		return !!(Options & EFastReferenceCollectorOptions::AutogenerateTokenStream);
   282  	}
   283  	constexpr FORCEINLINE bool ShouldProcessNoOpTokens() const
   284  	{
   285  		return !!(Options & EFastReferenceCollectorOptions::ProcessNoOpTokens);
   286  	}
   287  	constexpr FORCEINLINE bool ShouldProcessWeakReferences() const
   288  	{
   289  		return !!(Options & EFastReferenceCollectorOptions::ProcessWeakReferences);
   290  	}
   291  	
   292  	class FCollectorTaskQueue
   293  	{
   294  		TFastReferenceCollector*	Owner;
   295  		ArrayPoolType& ArrayPool;
   296  		TLockFreePointerListUnordered<FGCArrayStruct, PLATFORM_CACHE_LINE_SIZE> Tasks;
   297  
   298  		FCriticalSection WaitingThreadsLock;
   299  		TArray<FEvent*> WaitingThreads;
   300  		bool bDone;
   301  		int32 NumThreadsStarted;
   302  	public:
   303  
   304  		FCollectorTaskQueue(TFastReferenceCollector* InOwner, ArrayPoolType& InArrayPool)
   305  			: Owner(InOwner)
   306  			, ArrayPool(InArrayPool)
   307  			, bDone(false)
   308  			, NumThreadsStarted(0)
   309  		{
   310  		}
   311  
   312  		void CheckDone()
   313  		{
   314  			FScopeLock Lock(&WaitingThreadsLock);
   315  			check(bDone);
   316  			check(!Tasks.Pop());
   317  			check(!WaitingThreads.Num());
   318  			check(NumThreadsStarted);
   319  		}
   320  
   321  		FORCENOINLINE void AddTask(const TArray<UObject*>* InObjectsToSerialize, int32 StartIndex, int32 NumObjects)
   322  		{
   323  			FGCArrayStruct* ArrayStruct = ArrayPool.GetArrayStructFromPool();
   324  			ArrayStruct->ObjectsToSerialize.AddUninitialized(NumObjects);
   325  			FMemory::Memcpy(ArrayStruct->ObjectsToSerialize.GetData(), InObjectsToSerialize->GetData() + StartIndex, NumObjects * sizeof(UObject*));
   326  			Tasks.Push(ArrayStruct);
   327  
   328  			FEvent* WaitingThread = nullptr;
   329  			{
   330  				FScopeLock Lock(&WaitingThreadsLock);
   331  				check(!bDone);
   332  				if (WaitingThreads.Num())
   333  				{
   334  					WaitingThread = WaitingThreads.Pop();
   335  				}
   336  			}
   337  			if (WaitingThread)
   338  			{
   339  				WaitingThread->Trigger();
   340  			}
   341  		}
   342  
   343  		FORCENOINLINE void DoTask()
   344  		{
   345  			{
   346  				FScopeLock Lock(&WaitingThreadsLock);
```

해설:

이 구간은 GC가 대량의 객체 참조를 어떻게 ‘빠르게’ 방문하는지 보여준다.

템플릿/인라인 기반 설계는 가상 호출/분기 비용을 줄여 대규모 반복에서 성능 이점을 얻는다.

배치/큐 구조가 보이면: 병렬 워커 스레드로 작업을 쪼개 락 경쟁을 줄이려는 의도다.

Processor가 분리되어 있으면: 동일한 수집 루프를 여러 모드(예: 검증 포함/미포함)로 재사용하기 위함이다.


핵심 코드 주변: 'ProcessObjectArray'  —  FastReferenceCollector.h:348~

코드(발췌):

```cpp
   348  				{
   349  					return;
   350  				}
   351  				NumThreadsStarted++;
   352  			}
   353  			while (true)
   354  			{
   355  				FGCArrayStruct* ArrayStruct = Tasks.Pop();
   356  				while (!ArrayStruct)
   357  				{
   358  					if (bDone)
   359  					{
   360  						return;
   361  					}
   362  					FEvent* WaitEvent = nullptr;
   363  					{
   364  						FScopeLock Lock(&WaitingThreadsLock);
   365  						if (bDone)
   366  						{
   367  							return;
   368  						}
   369  						ArrayStruct = Tasks.Pop();
   370  						if (!ArrayStruct)
   371  						{
   372  							if (WaitingThreads.Num() + 1 == NumThreadsStarted)
   373  							{
   374  								bDone = true;
   375  								FPlatformMisc::MemoryBarrier();
   376  								for (FEvent* WaitingThread : WaitingThreads)
   377  								{
   378  									WaitingThread->Trigger();
   379  								}
   380  								WaitingThreads.Empty();
   381  								return;
   382  							}
   383  							else
   384  							{
   385  								WaitEvent = FPlatformProcess::GetSynchEventFromPool(false);
   386  								WaitingThreads.Push(WaitEvent);
   387  							}
   388  						}
   389  					}
   390  					if (ArrayStruct)
   391  					{
   392  						check(!WaitEvent);
   393  					}
   394  					else
   395  					{
   396  						check(WaitEvent);
   397  						WaitEvent->Wait();
   398  						FPlatformProcess::ReturnSynchEventToPool(WaitEvent);
   399  						ArrayStruct = Tasks.Pop();
   400  						check(!ArrayStruct || !bDone);
   401  					}
   402  				}
   403  				Owner->ProcessObjectArray(*ArrayStruct, FGraphEventRef());
   404  				ArrayPool.ReturnToPool(ArrayStruct);
   405  			}
   406  		}
   407  	};
   408  
   409  	/** Task graph task responsible for processing UObject array */
   410  	class FCollectorTaskProcessorTask
   411  	{
   412  		FCollectorTaskQueue& TaskQueue;
   413  		ENamedThreads::Type DesiredThread;
   414  	public:
   415  		FCollectorTaskProcessorTask(FCollectorTaskQueue& InTaskQueue, ENamedThreads::Type InDesiredThread)
   416  			: TaskQueue(InTaskQueue)
   417  			, DesiredThread(InDesiredThread)
   418  		{
   419  		}
   420  		FORCEINLINE TStatId GetStatId() const
   421  		{
   422  			RETURN_QUICK_DECLARE_CYCLE_STAT(FCollectorTaskProcessorTask, STATGROUP_TaskGraphTasks);
   423  		}
   424  		ENamedThreads::Type GetDesiredThread()
   425  		{
   426  			return DesiredThread;
   427  		}
   428  		static ESubsequentsMode::Type GetSubsequentsMode()
   429  		{
   430  			return ESubsequentsMode::TrackSubsequents;
   431  		}
   432  		void DoTask(ENamedThreads::Type CurrentThread, FGraphEventRef& MyCompletionGraphEvent)
   433  		{
   434  			TaskQueue.DoTask();
   435  		}
   436  	};
   437  
   438  	/** Task graph task responsible for processing UObject array */
   439  	class FCollectorTask
   440  	{
   441  		TFastReferenceCollector*	Owner;
   442  		FGCArrayStruct*	ArrayStruct;
   443  		ArrayPoolType& ArrayPool;
   444  
   445  	public:
   446  		FCollectorTask(TFastReferenceCollector* InOwner, const TArray<UObject*>* InObjectsToSerialize, int32 StartIndex, int32 NumObjects, ArrayPoolType& InArrayPool)
   447  			: Owner(InOwner)
   448  			, ArrayStruct(InArrayPool.GetArrayStructFromPool())
   449  			, ArrayPool(InArrayPool)
   450  		{
   451  			ArrayStruct->ObjectsToSerialize.AddUninitialized(NumObjects);
   452  			FMemory::Memcpy(ArrayStruct->ObjectsToSerialize.GetData(), InObjectsToSerialize->GetData() + StartIndex, NumObjects * sizeof(UObject*));
   453  		}
   454  		~FCollectorTask()
   455  		{
   456  			ArrayPool.ReturnToPool(ArrayStruct);
   457  		}
```

해설:

이 구간은 GC가 대량의 객체 참조를 어떻게 ‘빠르게’ 방문하는지 보여준다.

템플릿/인라인 기반 설계는 가상 호출/분기 비용을 줄여 대규모 반복에서 성능 이점을 얻는다.

배치/큐 구조가 보이면: 병렬 워커 스레드로 작업을 쪼개 락 경쟁을 줄이려는 의도다.

Processor가 분리되어 있으면: 동일한 수집 루프를 여러 모드(예: 검증 포함/미포함)로 재사용하기 위함이다.



4. 참조 열거의 핵: 토큰 스트림과 Class.h / Class.cpp

GC가 ‘UPROPERTY로 표시된 멤버’를 자동으로 추적할 수 있는 이유는, UHT가 생성한 리플렉션 정보가 런타임에서 ‘참조 토큰 스트림(Reference Token Stream)’ 형태로 조립되고, GC가 이를 선형적으로 스캔하기 때문이다.

4.1 Class.h에서 보이는 토큰 스트림 관련 선언

선언/주석 주변: 'Reference token stream'  —  Class.h:2733~

코드(발췌):

```cpp
  2733  	void* GetOrCreateSparseClassData() { return SparseClassData ? SparseClassData : CreateSparseClassData(); }
  2734  
  2735  	/**
  2736  	 * Returns a pointer to the type of the sidecar data structure if one is specified.
  2737  	 */
  2738  	virtual UScriptStruct* GetSparseClassDataStruct() const;
  2739  
  2740  	void SetSparseClassDataStruct(UScriptStruct* InSparseClassDataStruct);
  2741  
  2742  	/** Assemble reference token streams for all classes if they haven't had it assembled already */
  2743  	static void AssembleReferenceTokenStreams();
  2744  
  2745  #if WITH_EDITOR
  2746  	void GenerateFunctionList(TArray<FName>& OutArray) const 
  2747  	{ 
  2748  		FuncMap.GenerateKeyArray(OutArray); 
  2749  	}
  2750  #endif // WITH_EDITOR
  2751  
  2752  private:
  2753  	void* CreateSparseClassData();
  2754  
  2755  	void CleanupSparseClassData();
  2756  
  2757  #if WITH_EDITOR
  2758  	/** Provides access to attributes of the underlying C++ class. Should never be unset. */
  2759  	TOptional<FCppClassTypeInfo> CppTypeInfo;
  2760  #endif
  2761  
  2762  	/** Map of all functions by name contained in this class */
  2763  	TMap<FName, UFunction*> FuncMap;
  2764  
  2765  	/** A cache of all functions by name that exist in a parent (superclass or interface) context */
  2766  	mutable TMap<FName, UFunction*> SuperFuncMap;
  2767  
  2768  	/** Scope lock to avoid the SuperFuncMap being read and written to simultaneously on multiple threads. */
  2769  	mutable FRWLock SuperFuncMapLock;
  2770  
  2771  public:
  2772  	/**
  2773  	 * The list of interfaces which this class implements, along with the pointer property that is located at the offset of the interface's vtable.
  2774  	 * If the interface class isn't native, the property will be null.
  2775  	 */
  2776  	TArray<FImplementedInterface> Interfaces;
  2777  
  2778  	/** Reference token stream used by realtime garbage collector, finalized in AssembleReferenceTokenStream */
  2779  	FGCReferenceTokenStream ReferenceTokenStream;
  2780  	/** CS for the token stream. Token stream can assemble code can sometimes be called from two threads throuh a web of async loading calls. */
  2781  	FCriticalSection ReferenceTokenStreamCritical;
  2782  
  2783  	/** This class's native functions. */
  2784  	TArray<FNativeFunctionLookup> NativeFunctionLookupTable;
  2785  
  2786  public:
  2787  	// Constructors
  2788  	UClass(const FObjectInitializer& ObjectInitializer = FObjectInitializer::Get());
  2789  	explicit UClass(const FObjectInitializer& ObjectInitializer, UClass* InSuperClass);
  2790  	UClass( EStaticConstructor, FName InName, uint32 InSize, uint32 InAlignment, EClassFlags InClassFlags, EClassCastFlags InClassCastFlags,
  2791  		const TCHAR* InClassConfigName, EObjectFlags InFlags, ClassConstructorType InClassConstructor,
  2792  		ClassVTableHelperCtorCallerType InClassVTableHelperCtorCaller,
  2793  		ClassAddReferencedObjectsType InClassAddReferencedObjects);
  2794  
  2795  #if WITH_HOT_RELOAD
  2796  	/**
  2797  	 * Called when a class is reloading from a DLL...updates various information in-place.
  2798  	 * @param	InSize							sizeof the class
  2799  	 * @param	InClassFlags					Class flags for the class
  2800  	 * @param	InClassCastFlags				Cast Flags for the class
  2801  	 * @param	InConfigName					Config Name
  2802  	 * @param	InClassConstructor				Pointer to InternalConstructor<TClass>
  2803  	 * @param	TClass_Super_StaticClass		Static class of the super class
  2804  	 * @param	TClass_WithinClass_StaticClass	Static class of the WithinClass
  2805  	 */
  2806  	bool HotReloadPrivateStaticClass(
  2807  		uint32			InSize,
  2808  		EClassFlags		InClassFlags,
  2809  		EClassCastFlags	InClassCastFlags,
  2810  		const TCHAR*    InConfigName,
  2811  		ClassConstructorType InClassConstructor,
  2812  		ClassVTableHelperCtorCallerType InClassVTableHelperCtorCaller,
  2813  		ClassAddReferencedObjectsType InClassAddReferencedObjects,
  2814  		class UClass* TClass_Super_StaticClass,
  2815  		class UClass* TClass_WithinClass_StaticClass
  2816  		);
  2817  
  2818  
  2819  	/**
  2820  	* Replace a native function in the  internal native function table
  2821  	* @param	InName							name of the function
  2822  	* @param	InPointer						pointer to the function
```

해설:

‘AssembleReferenceTokenStreams’는 부팅 단계 등에서 전체 클래스의 토큰 스트림을 조립하는 엔트리다.

‘AssembleReferenceTokenStream’(단수)는 개별 UClass의 토큰 스트림(또는 RTGC용)을 구축하는 핵심 루틴이다. (정의는 다른 cpp에 있을 수 있음)

‘EmitObjectReference/EmitObjectArrayReference’는 ‘이 오프셋에 UObject 참조가 있다’를 스트림에 기록하는 빌딩 블록이다.


선언/주석 주변: 'AssembleReferenceTokenStream'  —  Class.h:2698~

코드(발췌):

```cpp
  2698  	bool IsAutoCollapseCategory(const TCHAR* InCategory) const;
  2699  	void GetClassGroupNames(TArray<FString>& OutClassGroupNames) const;
  2700  	bool IsClassGroupName(const TCHAR* InGroupName) const;
  2701  #endif
  2702  	/**
  2703  	 * Calls AddReferencedObjects static method on the specified object.
  2704  	 *
  2705  	 * @param This Object to call ARO on.
  2706  	 * @param Collector Reference collector.
  2707  	 */
  2708  	FORCEINLINE void CallAddReferencedObjects(UObject* This, FReferenceCollector& Collector) const
  2709  	{
  2710  		// The object must of this class type.
  2711  		check(This->IsA(this)); 
  2712  		// This is should always be set to something, at the very least to UObject::ARO
  2713  		check(ClassAddReferencedObjects != nullptr);
  2714  		ClassAddReferencedObjects(This, Collector);
  2715  	}
  2716  
  2717  	/** The class default object; used for delta serialization and object initialization */
  2718  	UObject* ClassDefaultObject;
  2719  
  2720  protected:
  2721  	/** This is where we store the data that is only changed per class instead of per instance */
  2722  	UPROPERTY()
  2723  	void* SparseClassData;
  2724  
  2725  	/** The struct used to store sparse class data. */
  2726  	UPROPERTY()
  2727  	UScriptStruct* SparseClassDataStruct;
  2728  
  2729  public:
  2730  	/**
  2731  	 * Returns a pointer to the sidecar data structure. This function will create an instance of the data structure if one has been specified and it has not yet been created.
  2732  	 */
  2733  	void* GetOrCreateSparseClassData() { return SparseClassData ? SparseClassData : CreateSparseClassData(); }
  2734  
  2735  	/**
  2736  	 * Returns a pointer to the type of the sidecar data structure if one is specified.
  2737  	 */
  2738  	virtual UScriptStruct* GetSparseClassDataStruct() const;
  2739  
  2740  	void SetSparseClassDataStruct(UScriptStruct* InSparseClassDataStruct);
  2741  
  2742  	/** Assemble reference token streams for all classes if they haven't had it assembled already */
  2743  	static void AssembleReferenceTokenStreams();
  2744  
  2745  #if WITH_EDITOR
  2746  	void GenerateFunctionList(TArray<FName>& OutArray) const 
  2747  	{ 
  2748  		FuncMap.GenerateKeyArray(OutArray); 
  2749  	}
  2750  #endif // WITH_EDITOR
  2751  
  2752  private:
  2753  	void* CreateSparseClassData();
  2754  
  2755  	void CleanupSparseClassData();
  2756  
  2757  #if WITH_EDITOR
  2758  	/** Provides access to attributes of the underlying C++ class. Should never be unset. */
  2759  	TOptional<FCppClassTypeInfo> CppTypeInfo;
  2760  #endif
  2761  
  2762  	/** Map of all functions by name contained in this class */
  2763  	TMap<FName, UFunction*> FuncMap;
  2764  
  2765  	/** A cache of all functions by name that exist in a parent (superclass or interface) context */
  2766  	mutable TMap<FName, UFunction*> SuperFuncMap;
  2767  
  2768  	/** Scope lock to avoid the SuperFuncMap being read and written to simultaneously on multiple threads. */
  2769  	mutable FRWLock SuperFuncMapLock;
  2770  
  2771  public:
  2772  	/**
  2773  	 * The list of interfaces which this class implements, along with the pointer property that is located at the offset of the interface's vtable.
  2774  	 * If the interface class isn't native, the property will be null.
  2775  	 */
  2776  	TArray<FImplementedInterface> Interfaces;
  2777  
  2778  	/** Reference token stream used by realtime garbage collector, finalized in AssembleReferenceTokenStream */
  2779  	FGCReferenceTokenStream ReferenceTokenStream;
  2780  	/** CS for the token stream. Token stream can assemble code can sometimes be called from two threads throuh a web of async loading calls. */
  2781  	FCriticalSection ReferenceTokenStreamCritical;
  2782  
  2783  	/** This class's native functions. */
  2784  	TArray<FNativeFunctionLookup> NativeFunctionLookupTable;
  2785  
  2786  public:
  2787  	// Constructors
```

해설:

‘AssembleReferenceTokenStreams’는 부팅 단계 등에서 전체 클래스의 토큰 스트림을 조립하는 엔트리다.

‘AssembleReferenceTokenStream’(단수)는 개별 UClass의 토큰 스트림(또는 RTGC용)을 구축하는 핵심 루틴이다. (정의는 다른 cpp에 있을 수 있음)

‘EmitObjectReference/EmitObjectArrayReference’는 ‘이 오프셋에 UObject 참조가 있다’를 스트림에 기록하는 빌딩 블록이다.


선언/주석 주변: 'EGCReferenceType'  —  Class.h:3046~

코드(발췌):

```cpp
  3046  	 * @param FlagsToCheck	Class flags to check for
  3047  	 * @return true if all of the passed in flags are set (including no flags passed in), false otherwise
  3048  	 */
  3049  	FORCEINLINE bool HasAllClassFlags( EClassFlags FlagsToCheck ) const
  3050  	{
  3051  		return EnumHasAllFlags(ClassFlags, FlagsToCheck);
  3052  	}
  3053  
  3054  	/**
  3055  	 * Gets the class flags.
  3056  	 *
  3057  	 * @return	The class flags.
  3058  	 */
  3059  	FORCEINLINE EClassFlags GetClassFlags() const
  3060  	{
  3061  		return ClassFlags;
  3062  	}
  3063  
  3064  	/**
  3065  	 * Used to safely check whether the passed in flag is set.
  3066  	 *
  3067  	 * @param	FlagToCheck		the cast flag to check for (value should be one of the EClassCastFlags enums)
  3068  	 *
  3069  	 * @return	true if the passed in flag is set, false otherwise
  3070  	 *			(including no flag passed in)
  3071  	 */
  3072  	FORCEINLINE bool HasAnyCastFlag(EClassCastFlags FlagToCheck) const
  3073  	{
  3074  		return (ClassCastFlags&FlagToCheck) != 0;
  3075  	}
  3076  	FORCEINLINE bool HasAllCastFlags(EClassCastFlags FlagsToCheck) const
  3077  	{
  3078  		return (ClassCastFlags&FlagsToCheck) == FlagsToCheck;
  3079  	}
  3080  
  3081  	FString GetDescription() const;
  3082  
  3083  	/**
  3084  	 * Realtime garbage collection helper function used to emit token containing information about a 
  3085  	 * direct UObject reference at the passed in offset.
  3086  	 *
  3087  	 * @param Offset	Offset into object at which object reference is stored.
  3088  	 * @param DebugName	DebugName for this objects token. Only used in non-shipping builds.
  3089  	 * @param Kind		Optional parameter the describe the type of the reference.
  3090  	 */
  3091  	void EmitObjectReference(int32 Offset, const FName& DebugName, EGCReferenceType Kind = GCRT_Object);
  3092  
  3093  	/**
  3094  	 * Realtime garbage collection helper function used to emit token containing information about a 
  3095  	 * an array of UObject references at the passed in offset. Handles both TArray and TTransArray.
  3096  	 *
  3097  	 * @param Offset	Offset into object at which array of objects is stored.
  3098  	 * @param DebugName	DebugName for this objects token. Only used in non-shipping builds.
  3099  	 */
  3100  	void EmitObjectArrayReference(int32 Offset, const FName& DebugName);
  3101  
  3102  	/**
  3103  	 * Realtime garbage collection helper function used to indicate an array of structs at the passed in 
  3104  	 * offset.
  3105  	 *
  3106  	 * @param Offset	Offset into object at which array of structs is stored
  3107  	 * @param DebugName	DebugName for this objects token. Only used in non-shipping builds.
  3108  	 * @param Stride	Size/stride of struct
  3109  	 * @return	Index into token stream at which later on index to next token after the array is stored
  3110  	 *			which is used to skip over empty dynamic arrays
  3111  	 */
  3112  	uint32 EmitStructArrayBegin(int32 Offset, const FName& DebugName, int32 Stride);
  3113  
  3114  	/**
  3115  	 * Realtime garbage collection helper function used to indicate the end of an array of structs. The
  3116  	 * index following the current one will be written to the passed in SkipIndexIndex in order to be
  3117  	 * able to skip tokens for empty dynamic arrays.
  3118  	 *
  3119  	 * @param SkipIndexIndex
  3120  	 */
  3121  	void EmitStructArrayEnd(uint32 SkipIndexIndex);
  3122  
  3123  	/**
  3124  	 * Realtime garbage collection helper function used to indicate the beginning of a fixed array.
  3125  	 * All tokens issues between Begin and End will be replayed Count times.
  3126  	 *
  3127  	 * @param Offset	Offset at which fixed array starts.
  3128  	 * @param DebugName	DebugName for this objects token. Only used in non-shipping builds.
  3129  	 * @param Stride	Stride of array element, e.g. sizeof(struct) or sizeof(UObject*).
  3130  	 * @param Count		Fixed array count.
  3131  	 */
  3132  	void EmitFixedArrayBegin(int32 Offset, const FName& DebugName, int32 Stride, int32 Count);
  3133  	
  3134  	/**
  3135  	 * Realtime garbage collection helper function used to indicated the end of a fixed array.
```

해설:

‘AssembleReferenceTokenStreams’는 부팅 단계 등에서 전체 클래스의 토큰 스트림을 조립하는 엔트리다.

‘AssembleReferenceTokenStream’(단수)는 개별 UClass의 토큰 스트림(또는 RTGC용)을 구축하는 핵심 루틴이다. (정의는 다른 cpp에 있을 수 있음)

‘EmitObjectReference/EmitObjectArrayReference’는 ‘이 오프셋에 UObject 참조가 있다’를 스트림에 기록하는 빌딩 블록이다.


4.2 Class.cpp: 토큰 스트림 조립을 트리거하는 부트 루틴(발췌)

UClass::AssembleReferenceTokenStreams  —  Class.cpp:5325-5351

```cpp
  5325  void UClass::AssembleReferenceTokenStreams()
  5326  {
  5327  	SCOPED_BOOT_TIMING("AssembleReferenceTokenStreams (can be optimized)");
  5328  	// Iterate over all class objects and force the default objects to be created. Additionally also
  5329  	// assembles the token reference stream at this point. This is required for class objects that are
  5330  	// not taken into account for garbage collection but have instances that are.
  5331  	for (FRawObjectIterator It(false); It; ++It) // GetDefaultObject can create a new class, that need to be handled as well, so we cannot use TObjectIterator
  5332  	{
  5333  		if (UClass* Class = Cast<UClass>((UObject*)(It->Object)))
  5334  		{
  5335  			// Force the default object to be created (except when we're in the middle of exit purge -
  5336  			// this may happen if we exited PreInit early because of error).
  5337  			// 
  5338  			// Keep from handling script generated classes here, as those systems handle CDO 
  5339  			// instantiation themselves.
  5340  			if (!GExitPurge && !Class->HasAnyFlags(RF_BeingRegenerated))
  5341  			{
  5342  				Class->GetDefaultObject(); // Force the default object to be constructed if it isn't already
  5343  			}
  5344  			// Assemble reference token stream for garbage collection/ RTGC.
  5345  			if (!Class->HasAnyFlags(RF_ClassDefaultObject) && !Class->HasAnyClassFlags(CLASS_TokenStreamAssembled))
  5346  			{
  5347  				Class->AssembleReferenceTokenStream();
  5348  			}
  5349  		}
  5350  	}
  5351  }
```

주석형 해설:

이 루틴은 모든 클래스 오브젝트를 순회하며 CDO(Class Default Object)를 강제로 생성하고, 토큰 스트림을 조립한다.

중요 설계: GC가 클래스 자체를 수집 대상으로 삼지 않더라도, 그 클래스의 인스턴스는 GC 대상이므로 토큰 스트림이 반드시 필요하다.

‘GetDefaultObject가 새 클래스를 만들 수 있으니 TObjectIterator 대신 RawObjectIterator 사용’ 같은 주석은, 부트 타이밍에서 클래스 생성/등록의 재진입(re-entrancy) 위험을 회피하기 위한 선택이다.

4.3 왜 토큰 스트림이 GC 성능을 바꾸는가(논문식 설명)

토큰 스트림은 본질적으로 ‘참조 스캐닝 프로그램’을 데이터로 만들어 둔 것이다. 클래스의 UPROPERTY 레이아웃이 고정이라면, 런타임에 매번 리플렉션을 해석하지 않고도 선형 배열(토큰)을 순회하며 (오프셋, 타입, 컨테이너 정보)에 따라 참조를 방문할 수 있다.

장점 1(캐시): 토큰 배열과 오브젝트 메모리를 일정한 패턴으로 접근하게 되어 캐시 미스를 줄인다.

장점 2(분기): 다양한 타입 분기/가상 호출을 줄이고, 스위치/테이블 기반으로 예측 가능한 실행 흐름을 만든다.

장점 3(병렬화): 참조 열거가 빠르므로 워커 스레드로 마킹을 분산할 때 오버헤드 대비 이득이 커진다.


5. UObject 파괴 수명주기: Obj.cpp, UObjectBaseUtility.h

UE4는 파괴를 ‘단계적으로’ 수행한다. 파괴 단계는 GC의 Sweep/Purge와 강하게 연결되어 있으며, 리소스 해제의 비동기성(렌더 스레드/GPU)을 고려한 설계다.

ConditionalBeginDestroy  —  Obj.cpp:943-1015

코드(발췌):

```cpp
   943  bool UObject::ConditionalBeginDestroy()
   944  {
   945  #if !UE_BUILD_SHIPPING
   946  	// if this object wasn't marked (but some were) then that means it was created and destroyed since the SpikeMark command was given
   947  	// this object is contributing to the spike that is being investigated
   948  	if (DebugSpikeMarkAnnotation.Num() > 0)
   949  	{
   950  		if(!DebugSpikeMarkAnnotation.Get(this))
   951  		{
   952  			DebugSpikeMarkNames.Add(GetFullName());
   953  		}
   954  	}
   955  #endif
   956  	
   957  	check(IsValidLowLevel());
   958  	if( !HasAnyFlags(RF_BeginDestroyed) )
   959  	{
   960  		SetFlags(RF_BeginDestroyed);
   961  #if !(UE_BUILD_SHIPPING || UE_BUILD_TEST)
   962  		checkSlow(!DebugBeginDestroyed.Contains(this));
   963  		DebugBeginDestroyed.Add(this);
   964  #endif
   965  
   966  #if PROFILE_ConditionalBeginDestroy
   967  		double StartTime = FPlatformTime::Seconds();
   968  #endif
   969  
   970  		BeginDestroy();
   971  
   972  #if PROFILE_ConditionalBeginDestroy
   973  		float ThisTime = float(FPlatformTime::Seconds() - StartTime);
   974  
   975  		FTimeCnt& TimeCnt = MyProfile.FindOrAdd(GetClass()->GetFName());
   976  		TimeCnt.Count++;
   977  		TimeCnt.TotalTime += ThisTime;
   978  
   979  		static float TotalTime = 0.0f;
   980  		static int32 TotalCnt = 0;
   981  
   982  		TotalTime += ThisTime;
   983  		if ((++TotalCnt) % 1000 == 0)
   984  		{
   985  			UE_LOG(LogObj, Log, TEXT("ConditionalBeginDestroy %d cnt %fus"), TotalCnt, 1000.0f * 1000.0f * TotalTime / float(TotalCnt));
   986  
   987  			MyProfile.ValueSort(TLess<FTimeCnt>());
   988  
   989  			int32 NumPrint = 0;
   990  			for (auto& Item : MyProfile)
   991  			{
   992  				UE_LOG(LogObj, Log, TEXT("    %6d cnt %6.2fus per   %6.2fms total  %s"), Item.Value.Count, 1000.0f * 1000.0f * Item.Value.TotalTime / float(Item.Value.Count), 1000.0f * Item.Value.TotalTime, *Item.Key.ToString());
   993  				if (NumPrint++ > 30)
   994  				{
   995  					break;
   996  				}
   997  			}
   998  		}
   999  #endif
  1000  
  1001  
  1002  #if !(UE_BUILD_SHIPPING || UE_BUILD_TEST)
  1003  		if( DebugBeginDestroyed.Contains(this) )
  1004  		{
  1005  			// class might override BeginDestroy without calling Super::BeginDestroy();
  1006  			UE_LOG(LogObj, Fatal, TEXT("%s failed to route BeginDestroy"), *GetFullName() );
  1007  		}
  1008  #endif
  1009  		return true;
  1010  	}
  1011  	else 
  1012  	{
  1013  		return false;
  1014  	}
  1015  }
```

해설(왜 이렇게):

ConditionalBeginDestroy는 ‘파괴를 시작해도 되는지/이미 시작했는지’를 중앙에서 관리해 중복 호출과 재진입을 막는다.

BeginDestroy는 ‘리소스 해제 요청’을 시작하기 위한 훅이며, 즉시 완료가 아닐 수 있다.

FinishDestroy는 ‘실제 파괴 완료’를 의미하며, 이 시점 이후에만 메모리 반환이 안전해진다.

IsReadyForFinishDestroy 류 체크가 있으면: 비동기 해제(렌더 리소스 등)가 완료될 때까지 기다리기 위함이다.


BeginDestroy  —  Obj.cpp:758-801

코드(발췌):

```cpp
   758  void UObject::BeginDestroy()
   759  {
   760  	// Sanity assertion to ensure ConditionalBeginDestroy is the only code calling us.
   761  	if( !HasAnyFlags(RF_BeginDestroyed) )
   762  	{
   763  		UE_LOG(LogObj, Fatal,
   764  			TEXT("Trying to call UObject::BeginDestroy from outside of UObject::ConditionalBeginDestroy on object %s. Please fix up the calling code."),
   765  			*GetName()
   766  			);
   767  	}
   768  
   769  #if WITH_EDITORONLY_DATA
   770  	// Make sure the linker entry stays as 'bExportLoadFailed' if the entry was marked as such, 
   771  	// doing this prevents the object from being reloaded by subsequent load calls:
   772  	FLinkerLoad* Linker = GetLinker();
   773  	const int32 CachedLinkerIndex = GetLinkerIndex();
   774  	bool bLinkerEntryWasInvalid = false;
   775  	if(Linker && Linker->ExportMap.IsValidIndex(CachedLinkerIndex))
   776  	{
   777  		FObjectExport& ObjExport = Linker->ExportMap[CachedLinkerIndex];
   778  		bLinkerEntryWasInvalid = ObjExport.bExportLoadFailed;
   779  	}
   780  #endif // WITH_EDITORONLY_DATA
   781  
   782  	// Remove from linker's export table.
   783  	SetLinker( NULL, INDEX_NONE );
   784  	
   785  #if WITH_EDITORONLY_DATA
   786  	if(bLinkerEntryWasInvalid)
   787  	{
   788  		FObjectExport& ObjExport = Linker->ExportMap[CachedLinkerIndex];
   789  		ObjExport.bExportLoadFailed = true;
   790  	}
   791  #endif // WITH_EDITORONLY_DATA
   792  
   793  	LowLevelRename(NAME_None);
   794  	// Remove any associated external package, at this point
   795  	SetExternalPackage(nullptr);
   796  
   797  	// ensure BeginDestroy has been routed back to UObject::BeginDestroy.
   798  #if !(UE_BUILD_SHIPPING || UE_BUILD_TEST)
   799  	DebugBeginDestroyed.RemoveSingle(this);
   800  #endif
   801  }
```

해설(왜 이렇게):

ConditionalBeginDestroy는 ‘파괴를 시작해도 되는지/이미 시작했는지’를 중앙에서 관리해 중복 호출과 재진입을 막는다.

BeginDestroy는 ‘리소스 해제 요청’을 시작하기 위한 훅이며, 즉시 완료가 아닐 수 있다.

FinishDestroy는 ‘실제 파괴 완료’를 의미하며, 이 시점 이후에만 메모리 반환이 안전해진다.

IsReadyForFinishDestroy 류 체크가 있으면: 비동기 해제(렌더 리소스 등)가 완료될 때까지 기다리기 위함이다.


FinishDestroy  —  Obj.cpp:804-822

코드(발췌):

```cpp
   804  void UObject::FinishDestroy()
   805  {
   806  	if( !HasAnyFlags(RF_FinishDestroyed) )
   807  	{
   808  		UE_LOG(LogObj, Fatal,
   809  			TEXT("Trying to call UObject::FinishDestroy from outside of UObject::ConditionalFinishDestroy on object %s. Please fix up the calling code."),
   810  			*GetName()
   811  			);
   812  	}
   813  
   814  	check( !GetLinker() );
   815  	check( GetLinkerIndex()	== INDEX_NONE );
   816  
   817  	DestroyNonNativeProperties();
   818  
   819  #if !(UE_BUILD_SHIPPING || UE_BUILD_TEST)
   820  	DebugFinishDestroyed.RemoveSingle(this);
   821  #endif
   822  }
```

해설(왜 이렇게):

ConditionalBeginDestroy는 ‘파괴를 시작해도 되는지/이미 시작했는지’를 중앙에서 관리해 중복 호출과 재진입을 막는다.

BeginDestroy는 ‘리소스 해제 요청’을 시작하기 위한 훅이며, 즉시 완료가 아닐 수 있다.

FinishDestroy는 ‘실제 파괴 완료’를 의미하며, 이 시점 이후에만 메모리 반환이 안전해진다.

IsReadyForFinishDestroy 류 체크가 있으면: 비동기 해제(렌더 리소스 등)가 완료될 때까지 기다리기 위함이다.


ConditionalFinishDestroy  —  Obj.cpp:1017-1047

코드(발췌):

```cpp
  1017  bool UObject::ConditionalFinishDestroy()
  1018  {
  1019  	check(IsValidLowLevel());
  1020  	if( !HasAnyFlags(RF_FinishDestroyed) )
  1021  	{
  1022  		SetFlags(RF_FinishDestroyed);
  1023  #if !(UE_BUILD_SHIPPING || UE_BUILD_TEST)
  1024  		checkSlow(!DebugFinishDestroyed.Contains(this));
  1025  		DebugFinishDestroyed.Add(this);
  1026  #endif
  1027  		FinishDestroy();
  1028  
  1029  		// Make sure this object can't be accessed via weak pointers after it's been FinishDestroyed
  1030  		GUObjectArray.ResetSerialNumber(this);
  1031  
  1032  		// Make sure this object can't be found through any delete listeners (annotation maps etc) after it's been FinishDestroyed
  1033  		GUObjectArray.RemoveObjectFromDeleteListeners(this);
  1034  
  1035  #if !(UE_BUILD_SHIPPING || UE_BUILD_TEST)
  1036  		if( DebugFinishDestroyed.Contains(this) )
  1037  		{
  1038  			UE_LOG(LogObj, Fatal, TEXT("%s failed to route FinishDestroy"), *GetFullName() );
  1039  		}
  1040  #endif
  1041  		return true;
  1042  	}
  1043  	else 
  1044  	{
  1045  		return false;
  1046  	}
  1047  }
```

해설(왜 이렇게):

ConditionalBeginDestroy는 ‘파괴를 시작해도 되는지/이미 시작했는지’를 중앙에서 관리해 중복 호출과 재진입을 막는다.

BeginDestroy는 ‘리소스 해제 요청’을 시작하기 위한 훅이며, 즉시 완료가 아닐 수 있다.

FinishDestroy는 ‘실제 파괴 완료’를 의미하며, 이 시점 이후에만 메모리 반환이 안전해진다.

IsReadyForFinishDestroy 류 체크가 있으면: 비동기 해제(렌더 리소스 등)가 완료될 때까지 기다리기 위함이다.


5.2 UObjectBaseUtility: Root/PendingKill 관련(발췌)

AddToRoot  —  UObjectBaseUtility.h:189-192

```cpp
   189  	FORCEINLINE void AddToRoot()
   190  	{
   191  		GUObjectArray.IndexToObject(InternalIndex)->SetRootSet();
   192  	}
```

해설:

AddToRoot/RemoveFromRoot는 RootSet에 직접 영향을 주므로, ‘살아있음’의 최상위 강제 장치다.

MarkPendingKill/IsPendingKill은 게임 로직 파괴 예약과 GC 정리의 경계를 만든다.

IsValidLowLevel 계열은 디버깅/안전성 체크로, shipping에서는 비용을 줄이는 경우가 많다.


RemoveFromRoot  —  UObjectBaseUtility.h:195-198

```cpp
   195  	FORCEINLINE void RemoveFromRoot()
   196  	{
   197  		GUObjectArray.IndexToObject(InternalIndex)->ClearRootSet();
   198  	}
```

해설:

AddToRoot/RemoveFromRoot는 RootSet에 직접 영향을 주므로, ‘살아있음’의 최상위 강제 장치다.

MarkPendingKill/IsPendingKill은 게임 로직 파괴 예약과 GC 정리의 경계를 만든다.

IsValidLowLevel 계열은 디버깅/안전성 체크로, shipping에서는 비용을 줄이는 경우가 많다.


IsPendingKill  —  UObjectBaseUtility.h:163-166

```cpp
   163  	FORCEINLINE bool IsPendingKill() const
   164  	{
   165  		return GUObjectArray.IndexToObject(InternalIndex)->IsPendingKill();
   166  	}
```

해설:

AddToRoot/RemoveFromRoot는 RootSet에 직접 영향을 주므로, ‘살아있음’의 최상위 강제 장치다.

MarkPendingKill/IsPendingKill은 게임 로직 파괴 예약과 GC 정리의 경계를 만든다.

IsValidLowLevel 계열은 디버깅/안전성 체크로, shipping에서는 비용을 줄이는 경우가 많다.


MarkPendingKill  —  UObjectBaseUtility.h:171-175

```cpp
   171  	FORCEINLINE void MarkPendingKill()
   172  	{
   173  		check(!IsRooted());
   174  		GUObjectArray.IndexToObject(InternalIndex)->SetPendingKill();
   175  	}
```

해설:

AddToRoot/RemoveFromRoot는 RootSet에 직접 영향을 주므로, ‘살아있음’의 최상위 강제 장치다.

MarkPendingKill/IsPendingKill은 게임 로직 파괴 예약과 GC 정리의 경계를 만든다.

IsValidLowLevel 계열은 디버깅/안전성 체크로, shipping에서는 비용을 줄이는 경우가 많다.



6. 전역 오브젝트 레지스트리: UObjectArray.h / UObjectArray.cpp

GUObjectArray는 ‘모든 UObject의 인덱스/시리얼/상태 플래그’를 보관하는 전역 레지스트리다. GC는 여기의 엔트리를 스캔하고 플래그를 조작하며, WeakObjectPtr은 (index, serial)로 유효성을 판단한다.

6.1 UObjectArray.h 핵심 구조(발췌)

구조/주석 주변: 'FUObjectArray' — UObjectArray.h:520~

```cpp
   520  	* Thread safe, if it is valid now, it is valid forever. This might return nullptr, but by then, some other thread might have made it non-nullptr.
   521  	**/
   522  	FORCEINLINE FUObjectItem const& operator[](int32 Index) const
   523  	{
   524  		FUObjectItem const* ItemPtr = GetObjectPtr(Index);
   525  		check(ItemPtr);
   526  		return *ItemPtr;
   527  	}
   528  	FORCEINLINE FUObjectItem& operator[](int32 Index)
   529  	{
   530  		FUObjectItem* ItemPtr = GetObjectPtr(Index);
   531  		check(ItemPtr);
   532  		return *ItemPtr;
   533  	}
   534  
   535  	int32 AddRange(int32 NumToAdd) TSAN_SAFE
   536  	{
   537  		int32 Result = NumElements;
   538  		checkf(Result + NumToAdd <= MaxElements, TEXT("Maximum number of UObjects (%d) exceeded, make sure you update MaxObjectsInGame/MaxObjectsInEditor/MaxObjectsInProgram in project settings."), MaxElements);
   539  		ExpandChunksToIndex(Result + NumToAdd - 1);
   540  		NumElements += NumToAdd;
   541  		return Result;
   542  	}
   543  
   544  	int32 AddSingle() TSAN_SAFE
   545  	{
   546  		return AddRange(1);
   547  	}
   548  
   549  	/**
   550  	* Return a naked pointer to the fundamental data structure for debug visualizers.
   551  	**/
   552  	FUObjectItem*** GetRootBlockForDebuggerVisualizers()
   553  	{
   554  		return nullptr;
   555  	}
   556      
   557      int64 GetAllocatedSize() const
   558      {
   559          return MaxChunks * sizeof(FUObjectItem*) + NumChunks * NumElementsPerChunk * sizeof(FUObjectItem);
   560      }
   561  };
   562  
   563  /***
   564  *
   565  * FUObjectArray replaces the functionality of GObjObjects and UObject::Index
   566  *
   567  * Note the layout of this data structure is mostly to emulate the old behavior and minimize code rework during code restructure.
   568  * Better data structures could be used in the future, for example maybe all that is needed is a TSet<UObject *>
   569  * One has to be a little careful with this, especially with the GC optimization. I have seen spots that assume
   570  * that non-GC objects come before GC ones during iteration.
   571  *
   572  **/
   573  class COREUOBJECT_API FUObjectArray
   574  {
   575  	friend class UObject;
   576  private:
   577  	/**
   578  	 * Reset the serial number from the game thread to invalidate all weak object pointers to it
   579  	 *
   580  	 * @param Object to reset
   581  	 */
   582  	void ResetSerialNumber(UObjectBase* Object);
   583  
   584  public:
   585  
   586  	enum ESerialNumberConstants
   587  	{
   588  		START_SERIAL_NUMBER = 1000,
   589  	};
   590  
   591  	/**
   592  	 * Base class for UObjectBase create class listeners
   593  	 */
   594  	class FUObjectCreateListener
   595  	{
   596  	public:
   597  		virtual ~FUObjectCreateListener() {}
   598  		/**
   599  		* Provides notification that a UObjectBase has been added to the uobject array
   600  		 *
   601  		 * @param Object object that has been destroyed
   602  		 * @param Index	index of object that is being deleted
   603  		 */
   604  		virtual void NotifyUObjectCreated(const class UObjectBase *Object, int32 Index)=0;
   605  
   606  		/**
   607  		 * Called when UObject Array is being shut down, this is where all listeners should be removed from it 
   608  		 */
   609  		virtual void OnUObjectArrayShutdown()=0;
```

해설:

GC는 ‘전역 객체 목록’을 한 번 훑는 패턴을 자주 사용한다. (플래그 초기화/수집)

RawObjectIterator는 부트/GC 같은 민감한 타이밍에서 클래스 생성 재진입 문제를 고려해 사용될 수 있다.


구조/주석 주변: 'GUObjectArray' — UObjectArray.h:1003~

```cpp
  1003  
  1004  		FORCEINLINE int32 GetIndex() const
  1005  		{
  1006  			return Index;
  1007  		}
  1008  
  1009  	protected:
  1010  
  1011  		/**
  1012  		 * Dereferences the iterator with an ordinary name for clarity in derived classes
  1013  		 *
  1014  		 * @return	the UObject at the iterator
  1015  		 */
  1016  		FORCEINLINE FUObjectItem* GetObject() const
  1017  		{ 
  1018  			return CurrentObject;
  1019  		}
  1020  		/**
  1021  		 * Iterator advance with ordinary name for clarity in subclasses
  1022  		 * @return	true if the iterator points to a valid object, false if iteration is complete
  1023  		 */
  1024  		FORCEINLINE bool Advance()
  1025  		{
  1026  			//@todo UE4 check this for LHS on Index on consoles
  1027  			FUObjectItem* NextObject = nullptr;
  1028  			CurrentObject = nullptr;
  1029  			while(++Index < Array.GetObjectArrayNum())
  1030  			{
  1031  				NextObject = const_cast<FUObjectItem*>(&Array.ObjObjects[Index]);
  1032  				if (NextObject->Object)
  1033  				{
  1034  					CurrentObject = NextObject;
  1035  					return true;
  1036  				}
  1037  			}
  1038  			return false;
  1039  		}
  1040  
  1041  		/** Gets the array this iterator iterates over */
  1042  		const FUObjectArray& GetIteratedArray() const
  1043  		{
  1044  			return Array;
  1045  		}
  1046  
  1047  	private:
  1048  		/** the array that we are iterating on, probably always GUObjectArray */
  1049  		const FUObjectArray& Array;
  1050  		/** index of the current element in the object array */
  1051  		int32 Index;
  1052  		/** Current object */
  1053  		mutable FUObjectItem* CurrentObject;
  1054  	};
  1055  
  1056  private:
  1057  
  1058  	//typedef TStaticIndirectArrayThreadSafeRead<UObjectBase, 8 * 1024 * 1024 /* Max 8M UObjects */, 16384 /* allocated in 64K/128K chunks */ > TUObjectArray;
  1059  	typedef FChunkedFixedUObjectArray TUObjectArray;
  1060  
  1061  	// note these variables are left with the Obj prefix so they can be related to the historical GObj versions
  1062  
  1063  	/** First index into objects array taken into account for GC.							*/
  1064  	int32 ObjFirstGCIndex;
  1065  	/** Index pointing to last object created in range disregarded for GC.					*/
  1066  	int32 ObjLastNonGCIndex;
  1067  	/** Maximum number of objects in the disregard for GC Pool */
  1068  	int32 MaxObjectsNotConsideredByGC;
  1069  
  1070  	/** If true this is the intial load and we should load objects int the disregarded for GC range.	*/
  1071  	bool OpenForDisregardForGC;
  1072  	/** Array of all live objects.											*/
  1073  	TUObjectArray ObjObjects;
  1074  	/** Synchronization object for all live objects.											*/
  1075  	mutable FCriticalSection ObjObjectsCritical;
  1076  	/** Available object indices.											*/
  1077  	TArray<int32> ObjAvailableList;
  1078  #if UE_GC_TRACK_OBJ_AVAILABLE
  1079  	/** Available object index count.										*/
  1080  	FThreadSafeCounter ObjAvailableCount;
  1081  #endif
  1082  	/**
  1083  	 * Array of things to notify when a UObjectBase is created
  1084  	 */
  1085  	TArray<FUObjectCreateListener* > UObjectCreateListeners;
  1086  	/**
  1087  	 * Array of things to notify when a UObjectBase is destroyed
  1088  	 */
  1089  	TArray<FUObjectDeleteListener* > UObjectDeleteListeners;
  1090  #if THREADSAFE_UOBJECTS
  1091  	FCriticalSection UObjectDeleteListenersCritical;
  1092  #endif
```

해설:

GC는 ‘전역 객체 목록’을 한 번 훑는 패턴을 자주 사용한다. (플래그 초기화/수집)

RawObjectIterator는 부트/GC 같은 민감한 타이밍에서 클래스 생성 재진입 문제를 고려해 사용될 수 있다.


6.2 UObjectArray.cpp: 인덱스 할당/해제 및 GC 관련 제어(발췌)

AllocateUObjectIndex  —  UObjectArray.cpp:189-245

```cpp
   189  void FUObjectArray::AllocateUObjectIndex(UObjectBase* Object, bool bMergingThreads /*= false*/)
   190  {
   191  	int32 Index = INDEX_NONE;
   192  	check(Object->InternalIndex == INDEX_NONE || bMergingThreads);
   193  
   194  	LockInternalArray();
   195  
   196  	// Special non- garbage collectable range.
   197  	if (OpenForDisregardForGC && DisregardForGCEnabled())
   198  	{
   199  		Index = ++ObjLastNonGCIndex;
   200  		// Check if we're not out of bounds, unless there hasn't been any gc objects yet
   201  		UE_CLOG(ObjLastNonGCIndex >= MaxObjectsNotConsideredByGC && ObjFirstGCIndex >= 0, LogUObjectArray, Fatal, TEXT("Unable to add more objects to disregard for GC pool (Max: %d)"), MaxObjectsNotConsideredByGC);
   202  		// If we haven't added any GC objects yet, it's fine to keep growing the disregard pool past its initial size.
   203  		if (ObjLastNonGCIndex >= MaxObjectsNotConsideredByGC)
   204  		{
   205  			Index = ObjObjects.AddSingle();
   206  			check(Index == ObjLastNonGCIndex);
   207  		}
   208  		MaxObjectsNotConsideredByGC = FMath::Max(MaxObjectsNotConsideredByGC, ObjLastNonGCIndex + 1);
   209  	}
   210  	// Regular pool/ range.
   211  	else
   212  	{
   213  		if (ObjAvailableList.Num() > 0)
   214  		{
   215  			Index = ObjAvailableList.Pop();
   216  #if UE_GC_TRACK_OBJ_AVAILABLE
   217  			const int32 AvailableCount = ObjAvailableCount.Decrement();
   218  			checkSlow(AvailableCount >= 0);
   219  #endif
   220  		}
   221  		else
   222  		{
   223  			// Make sure ObjFirstGCIndex is valid, otherwise we didn't close the disregard for GC set
   224  			check(ObjFirstGCIndex >= 0);
   225  			Index = ObjObjects.AddSingle();			
   226  		}
   227  		check(Index >= ObjFirstGCIndex && Index > ObjLastNonGCIndex);
   228  	}
   229  	// Add to global table.
   230  	FUObjectItem* ObjectItem = IndexToObject(Index);
   231  	UE_CLOG(ObjectItem->Object != nullptr, LogUObjectArray, Fatal, TEXT("Attempting to add %s at index %d but another object (0x%016llx) exists at that index!"), *Object->GetFName().ToString(), Index, (int64)(PTRINT)ObjectItem->Object);
   232  	ObjectItem->ResetSerialNumberAndFlags();
   233  	// At this point all not-compiled-in objects are not fully constructed yet and this is the earliest we can mark them as such
   234  	ObjectItem->SetFlags(EInternalObjectFlags::PendingConstruction);
   235  	ObjectItem->Object = Object;		
   236  	Object->InternalIndex = Index;
   237  
   238  	UnlockInternalArray();
   239  
   240  	//  @todo: threading: lock UObjectCreateListeners
   241  	for (int32 ListenerIndex = 0; ListenerIndex < UObjectCreateListeners.Num(); ListenerIndex++)
   242  	{
   243  		UObjectCreateListeners[ListenerIndex]->NotifyUObjectCreated(Object,Index);
   244  	}
   245  }
```

해설:

Allocate/FreeUObjectIndex는 WeakObjectPtr의 안전성과 직결된다(시리얼 증가로 ABA 문제 완화).

DisregardForGC는 엔진 초기화/부트 단계에서 특정 오브젝트를 GC에서 제외하거나 취급을 바꾸기 위한 메커니즘일 수 있다.

이 계층의 설계는 ‘전역 상태 + 고성능 반복’이 목적이므로 락/원자/캐시 고려가 강하게 반영된다.


FreeUObjectIndex  —  UObjectArray.cpp:284-306

```cpp
   284  void FUObjectArray::FreeUObjectIndex(UObjectBase* Object)
   285  {
   286  	// This should only be happening on the game thread (GC runs only on game thread when it's freeing objects)
   287  	check(IsInGameThread() || IsInGarbageCollectorThread());
   288  
   289  	// No need to call LockInternalArray(); here as it should already be locked by GC
   290  
   291  	int32 Index = Object->InternalIndex;
   292  	FUObjectItem* ObjectItem = IndexToObject(Index);
   293  	UE_CLOG(ObjectItem->Object != Object, LogUObjectArray, Fatal, TEXT("Removing object (0x%016llx) at index %d but the index points to a different object (0x%016llx)!"), (int64)(PTRINT)Object, Index, (int64)(PTRINT)ObjectItem->Object);
   294  	ObjectItem->Object = nullptr;
   295  	ObjectItem->ResetSerialNumberAndFlags();
   296  
   297  	// You cannot safely recycle indicies in the non-GC range
   298  	// No point in filling this list when doing exit purge. Nothing should be allocated afterwards anyway.
   299  	if (Index > ObjLastNonGCIndex && !GExitPurge)  
   300  	{
   301  		ObjAvailableList.Add(Index);
   302  #if UE_GC_TRACK_OBJ_AVAILABLE
   303  		ObjAvailableCount.Increment();
   304  #endif
   305  	}
   306  }
```

해설:

Allocate/FreeUObjectIndex는 WeakObjectPtr의 안전성과 직결된다(시리얼 증가로 ABA 문제 완화).

DisregardForGC는 엔진 초기화/부트 단계에서 특정 오브젝트를 GC에서 제외하거나 취급을 바꾸기 위한 메커니즘일 수 있다.

이 계층의 설계는 ‘전역 상태 + 고성능 반복’이 목적이므로 락/원자/캐시 고려가 강하게 반영된다.


CloseDisregardForGC  —  UObjectArray.cpp:120-177

```cpp
   120  void FUObjectArray::CloseDisregardForGC()
   121  {
   122  #if THREADSAFE_UOBJECTS
   123  	FScopeLock ObjObjectsLock(&ObjObjectsCritical);
   124  #else
   125  	// Disregard from GC pool is only available from the game thread, at least for now
   126  	check(IsInGameThread());
   127  #endif
   128  
   129  	check(OpenForDisregardForGC);
   130  
   131  	// Make sure all classes that have been loaded/created so far are properly initialized
   132  	if (!IsEngineExitRequested())
   133  	{
   134  		ProcessNewlyLoadedUObjects();
   135  
   136  		UClass::AssembleReferenceTokenStreams();
   137  
   138  		if (GIsInitialLoad)
   139  		{
   140  			// Iterate over all objects and mark them to be part of root set.
   141  			int32 NumAlwaysLoadedObjects = 0;
   142  			int32 NumRootObjects = 0;
   143  			for (FThreadSafeObjectIterator It; It; ++It)
   144  			{
   145  				UObject* Object = *It;
   146  				if (Object->IsSafeForRootSet())
   147  				{
   148  					NumRootObjects++;
   149  					Object->AddToRoot();
   150  				}
   151  				else if (Object->IsRooted())
   152  				{
   153  					Object->RemoveFromRoot();
   154  				}
   155  				NumAlwaysLoadedObjects++;
   156  			}
   157  
   158  			UE_LOG(LogUObjectArray, Log, TEXT("%i objects as part of root set at end of initial load."), NumAlwaysLoadedObjects);
   159  			if (GUObjectArray.DisregardForGCEnabled())
   160  			{
   161  				UE_LOG(LogUObjectArray, Log, TEXT("%i objects are not in the root set, but can never be destroyed because they are in the DisregardForGC set."), NumAlwaysLoadedObjects - NumRootObjects);
   162  			}
   163  
   164  			GUObjectAllocator.BootMessage();
   165  		}
   166  	}
   167  
   168  	// When disregard for GC pool is closed, make sure the first GC index is set after the last non-GC index.
   169  	// We do allow here for some slack if MaxObjectsNotConsideredByGC > (ObjLastNonGCIndex + 1) so that disregard for GC pool
   170  	// can be re-opened later.
   171  	ObjFirstGCIndex = FMath::Max(ObjFirstGCIndex, ObjLastNonGCIndex + 1);
   172  
   173  	UE_LOG(LogUObjectArray, Log, TEXT("CloseDisregardForGC: %d/%d objects in disregard for GC pool"), ObjLastNonGCIndex + 1, MaxObjectsNotConsideredByGC);	
   174  
   175  	OpenForDisregardForGC = false;
   176  	GIsInitialLoad = false;
   177  }
```

해설:

Allocate/FreeUObjectIndex는 WeakObjectPtr의 안전성과 직결된다(시리얼 증가로 ABA 문제 완화).

DisregardForGC는 엔진 초기화/부트 단계에서 특정 오브젝트를 GC에서 제외하거나 취급을 바꾸기 위한 메커니즘일 수 있다.

이 계층의 설계는 ‘전역 상태 + 고성능 반복’이 목적이므로 락/원자/캐시 고려가 강하게 반영된다.


OpenDisregardForGC  —  UObjectArray.cpp:112-118

```cpp
   112  void FUObjectArray::OpenDisregardForGC()
   113  {
   114  	check(IsInGameThread());
   115  	check(!OpenForDisregardForGC);
   116  	OpenForDisregardForGC = true;
   117  	UE_LOG(LogUObjectArray, Log, TEXT("OpenDisregardForGC: %d/%d objects in disregard for GC pool"), ObjLastNonGCIndex + 1, MaxObjectsNotConsideredByGC);
   118  }
```

해설:

Allocate/FreeUObjectIndex는 WeakObjectPtr의 안전성과 직결된다(시리얼 증가로 ABA 문제 완화).

DisregardForGC는 엔진 초기화/부트 단계에서 특정 오브젝트를 GC에서 제외하거나 취급을 바꾸기 위한 메커니즘일 수 있다.

이 계층의 설계는 ‘전역 상태 + 고성능 반복’이 목적이므로 락/원자/캐시 고려가 강하게 반영된다.



7. Cluster GC: UObjectClusters.cpp

클러스터 GC는 ‘함께 생존/파괴되는 객체 집합’을 만들어 Reachability 비용을 줄인다. Actor-Component-Subobject처럼 강하게 결합된 그래프에서 효과가 크다.

AddObjectToCluster  —  UObjectClusters.cpp:621-654

```cpp
   621  	void AddObjectToCluster(int32 ObjectIndex, FUObjectItem* ObjectItem, UObject* Obj, TArray<UObject*>& ObjectsToSerialize, bool bOuterAndClass)
   622  	{
   623  		// If we haven't finished loading, we can't be sure we know all the references
   624  		checkf(!Obj->HasAnyFlags(RF_NeedLoad), TEXT("%s hasn't been loaded (%s) but is being added to cluster %s"), 
   625  			*Obj->GetFullName(), 
   626  			*LoadFlagsToString(Obj),
   627  			*GetClusterRoot()->GetFullName());
   628  
   629  		check(ObjectItem->GetOwnerIndex() == 0 || ObjectItem->GetOwnerIndex() == ClusterRootIndex || ObjectIndex == ClusterRootIndex || GUObjectArray.IsDisregardForGC(Obj));
   630  		check(Obj->CanBeInCluster());
   631  		if (ObjectIndex != ClusterRootIndex && ObjectItem->GetOwnerIndex() == 0 && !GUObjectArray.IsDisregardForGC(Obj) && !Obj->IsRooted())
   632  		{
   633  			ObjectsToSerialize.Add(Obj);
   634  			check(!ObjectItem->HasAnyFlags(EInternalObjectFlags::ClusterRoot));
   635  			ObjectItem->SetOwnerIndex(ClusterRootIndex);
   636  			Cluster.Objects.Add(ObjectIndex);
   637  
   638  			if (bOuterAndClass)
   639  			{
   640  				UObject* ObjOuter = Obj->GetOuter();
   641  				if (ObjOuter)
   642  				{
   643  					HandleTokenStreamObjectReference(ObjectsToSerialize, Obj, ObjOuter, INDEX_NONE, true);
   644  				}
   645  				if (!Obj->GetClass()->HasAllClassFlags(CLASS_Native))
   646  				{
   647  					UObject* ObjectClass = Obj->GetClass();
   648  					HandleTokenStreamObjectReference(ObjectsToSerialize, Obj, ObjectClass, INDEX_NONE, true);
   649  					UObject* ObjectClassOuter = Obj->GetClass()->GetOuter();
   650  					HandleTokenStreamObjectReference(ObjectsToSerialize, Obj, ObjectClassOuter, INDEX_NONE, true);
   651  				}
   652  			}
   653  		}
   654  	}
```

해설(왜 이렇게):

클러스터 생성은 ‘마킹 비용 절감’이 목적이므로, 생성 기준(최소 크기/대상 타입)이 매우 중요하다.

클러스터는 루트 하나가 살면 내부가 같이 살 수 있으므로, 지나치면 메모리 유지가 늘어난다(성능↔메모리 트레이드오프).

Add/Remove/Destroy 경로가 분리되어 있다면: 런타임에 클러스터 멤버십이 변할 수 있기 때문(동적 월드).



8. 비-UObject 참조 보고: GCObject.h

UObject가 아닌 C++ 객체가 UObject를 소유(강참조)할 때, GC는 기본적으로 그 참조를 모른다. FGCObject는 이 간극을 메우는 표준 장치다.

8.1 FGCObject 인터페이스(발췌)

```cpp
     1  // Copyright Epic Games, Inc. All Rights Reserved.
     2  
     3  /*=============================================================================
     4  	GCObject.h: Abstract base class to allow non-UObject objects reference
     5  				UObject instances with proper handling of them by the
     6  				Garbage Collector.
     7  =============================================================================*/
     8  
     9  #pragma once
    10  
    11  #include "CoreMinimal.h"
    12  #include "UObject/ObjectMacros.h"
    13  #include "UObject/Object.h"
    14  
    15  class FGCObject;
    16  
    17  class COREUOBJECT_API FGCObject;
    18  
    19  /**
    20   * This nested class is used to provide a UObject interface between non
    21   * UObject classes and the UObject system. It handles forwarding all
    22   * calls of AddReferencedObjects() to objects/ classes that register with it.
    23   */
    24  class COREUOBJECT_API UGCObjectReferencer : public UObject
    25  {
    26  	/**
    27  	 * This is the list of objects that are referenced
    28  	 */
    29  	TArray<FGCObject*> ReferencedObjects;
    30  	/** Critical section used when adding and removing objects */
    31  	FCriticalSection ReferencedObjectsCritical;
    32  	/** True if we are currently inside AddReferencedObjects */
    33  	bool bIsAddingReferencedObjects = false;
    34  	/** Currently serializing FGCObject*, only valid if bIsAddingReferencedObjects */
    35  	FGCObject* CurrentlySerializingObject = nullptr;
    36  
    37  public:
    38  	DECLARE_CASTED_CLASS_INTRINSIC_WITH_API(UGCObjectReferencer, UObject, CLASS_Transient, TEXT("/Script/CoreUObject"), CASTCLASS_None, NO_API);
    39  
    40  	/**
    41  	 * Adds an object to the referencer list
    42  	 *
    43  	 * @param Object The object to add to the list
    44  	 */
    45  	void AddObject(FGCObject* Object);
    46  
    47  	/**
    48  	 * Removes an object from the referencer list
    49  	 *
    50  	 * @param Object The object to remove from the list
    51  	 */
    52  	void RemoveObject(FGCObject* Object);
    53  
    54  	/**
    55  	 * Get the name of the first FGCObject that owns this object.
    56  	 *
    57  	 * @param Object The object that we're looking for.
    58  	 * @param OutName the name of the FGCObject that reports this object.
    59  	 * @param bOnlyIfAddingReferenced Only try to find the name if we are currently inside AddReferencedObjects
    60  	 * @return true if the object was found.
    61  	 */
    62  	bool GetReferencerName(UObject* Object, FString& OutName, bool bOnlyIfAddingReferenced = false) const;
    63  
    64  	/**
    65  	 * Forwards this call to all registered objects so they can reference
    66  	 * any UObjects they depend upon
    67  	 *
    68  	 * @param InThis This UGCObjectReferencer object.
    69  	 * @param Collector The collector of referenced objects.
    70  	 */
    71  	static void AddReferencedObjects(UObject* InThis, FReferenceCollector& Collector);
    72  	
    73  	/**
    74  	 * Destroy function that gets called before the object is freed. This might
    75  	 * be as late as from the destructor.
    76  	 */
    77  	virtual void FinishDestroy() override;
    78  };
    79  
    80  
    81  /**
    82   * This class provides common registration for garbage collection for
    83   * non-UObject classes. It is an abstract base class requiring you to implement
    84   * the AddReferencedObjects() method.
    85   */
    86  class COREUOBJECT_API FGCObject
    87  {
    88  	bool bReferenceAdded = false;
    89  
    90  	void Init()
    91  	{
    92  		// Some objects can get created after the engine started shutting down (lazy init of singletons etc).
    93  		if (!IsEngineExitRequested())
    94  		{
    95  			StaticInit();
    96  			check(GGCObjectReferencer);
    97  			// Add this instance to the referencer's list
    98  			GGCObjectReferencer->AddObject(this);
    99  			bReferenceAdded = true;
   100  		}
   101  	}
   102  
   103  public:
   104  	/**
   105  	 * The static object referencer object that is shared across all
   106  	 * garbage collectible non-UObject objects.
   107  	 */
   108  	static UGCObjectReferencer* GGCObjectReferencer;
   109  
   110  	/**
   111  	 * Initializes the global object referencer and adds it to the root set.
   112  	 */
   113  	static void StaticInit(void)
   114  	{
   115  		if (GGCObjectReferencer == NULL)
   116  		{
   117  			GGCObjectReferencer = NewObject<UGCObjectReferencer>();
   118  			GGCObjectReferencer->AddToRoot();
   119  		}
   120  	}
   121  
   122  	/**
   123  	 * Tells the global object that forwards AddReferencedObjects calls on to objects
   124  	 * that a new object is requiring AddReferencedObjects call.
   125  	 */
   126  	FGCObject(void)
   127  	{
   128  		Init();
   129  	}
   130  
   131  	/** Copy constructor */
   132  	FGCObject(FGCObject const&)
   133  	{
   134  		Init();
   135  	}
   136  
   137  	/** Move constructor */
   138  	FGCObject(FGCObject&&)
   139  	{
   140  		Init();
   141  	}
   142  
   143  	/**
   144  	 * Removes this instance from the global referencer's list
   145  	 */
   146  	virtual ~FGCObject(void)
   147  	{
   148  		// GObjectSerializer will be NULL if this object gets destroyed after the exit purge.
   149  		// We want to make sure we remove any objects that were added to the GGCObjectReferencer during Init when exiting
   150  		if (GGCObjectReferencer && bReferenceAdded)
   151  		{
   152  			// Remove this instance from the referencer's list
   153  			GGCObjectReferencer->RemoveObject(this);
   154  		}
   155  	}
   156  
   157  	/**
   158  	 * Pure virtual that must be overloaded by the inheriting class. Use this
   159  	 * method to serialize any UObjects contained that you wish to keep around.
   160  	 *
   161  	 * @param Collector The collector of referenced objects.
   162  	 */
   163  	virtual void AddReferencedObjects( FReferenceCollector& Collector ) = 0;
   164  
   165  	/**
   166  	 * Use this method to report a name for your referencer.
   167  	 */
   168  	virtual FString GetReferencerName() const
   169  	{
   170  		return "Unknown FGCObject";
   171  	}
   172  
   173  	/**
   174  	 * Use this method to report how the specified object is referenced, if necessary
   175  	 */
   176  	virtual bool GetReferencerPropertyName(UObject* Object, FString& OutPropertyName) const
   177  	{
   178  		return false;
   179  	}
   180  };
```

해설:

핵심은 AddReferencedObjects(FReferenceCollector&)를 통해 ‘내가 잡고 있는 UObject 참조’를 GC에 보고하는 것.

GetReferencerName은 디버그/리포트에서 ‘누가 참조를 잡고 있나’를 추적하기 위한 메타 정보다.

이 설계는 ‘소유권/수명은 UObject 밖에서도 발생한다’는 엔진 현실을 반영한다.


9. 해시/탐색과 GC 상호작용: UObjectHash.cpp

UObjectHash는 이름/클래스/아우터 등의 키로 UObject를 빠르게 찾기 위한 해시 인프라다. GC는 Unreachable 객체를 unhash하여 탐색 경로에서 제거함으로써 무효 객체 접근 위험을 줄인다.

코드 주변: 'Unhash' — UObjectHash.cpp:1~

```cpp
     1  // Copyright Epic Games, Inc. All Rights Reserved.
     2  
     3  /*=============================================================================
     4  	UObjectHash.cpp: Unreal object name hashes
     5  =============================================================================*/
     6  
     7  #include "UObject/UObjectHash.h"
     8  #include "UObject/Class.h"
     9  #include "UObject/Package.h"
    10  #include "Misc/AsciiSet.h"
    11  #include "Misc/PackageName.h"
    12  #include "HAL/IConsoleManager.h"
    13  
    14  DEFINE_LOG_CATEGORY_STATIC(LogUObjectHash, Log, All);
    15  
    16  DECLARE_CYCLE_STAT( TEXT( "GetObjectsOfClass" ), STAT_Hash_GetObjectsOfClass, STATGROUP_UObjectHash );
    17  DECLARE_CYCLE_STAT( TEXT( "HashObject" ), STAT_Hash_HashObject, STATGROUP_UObjectHash );
    18  DECLARE_CYCLE_STAT( TEXT( "UnhashObject" ), STAT_Hash_UnhashObject, STATGROUP_UObjectHash );
    19  
    20  #if UE_GC_TRACK_OBJ_AVAILABLE
    21  DEFINE_STAT( STAT_Hash_NumObjects );
    22  #endif
    23  
    24  // Global UObject array instance
    25  FUObjectArray GUObjectArray;
    26  
    27  /**
    28   * This implementation will use more space than the UE3 implementation. The goal was to make UObjects smaller to save L2 cache space. 
    29   * The hash is rarely used at runtime. A more space-efficient implementation is possible.
    30   */
    31  
    32  
    33  /*
    34   * Special hash bucket to conserve memory.
    35   * Contains a pointer to head element and an optional list of items if more than one element exists in the bucket.
    36   * The item list is only allocated if needed.
    37   */
    38  struct FHashBucket
    39  {
    40  	friend struct FHashBucketIterator;
    41  
    42  	/** This always empty set is used to get an iterator if the bucket doesn't use a TSet (has only 1 element) */
    43  	static TSet<UObjectBase*> EmptyBucket;
    44  
    45  	/*
    46  	* If these are both null, this bucket is empty
    47  	* If the first one is null, but the second one is non-null, then the second one is a TSet pointer
    48  	* If the first one is not null, then it is a uobject ptr, and the second ptr is either null or a second element
    49  	*/
    50  	void *ElementsOrSetPtr[2];
    51  
    52  #if !UE_BUILD_SHIPPING
    53  	/** If true this bucket is being iterated over and no Add or Remove operations are allowed */
    54  	int32 ReadOnlyLock;
    55  
    56  	FORCEINLINE void Lock()
    57  	{
    58  		ReadOnlyLock++;
    59  	}
    60  
    61  	FORCEINLINE void Unlock()
    62  	{
    63  		ReadOnlyLock--;
    64  		check(ReadOnlyLock >= 0);
    65  	}
    66  #endif // !UE_BUILD_SHIPPING
```

해설:

해시에서 제거(unhash) 시점이 GC 파이프라인에서 앞쪽에 위치하면, 이후 시스템이 찾기를 통해 무효 객체를 다시 잡을 가능성을 줄인다.

이 계층은 ‘읽기 빈도 매우 높음’ → ‘쓰기(추가/삭제)는 상대적으로 낮음’ 패턴을 가질 수 있어, 락 전략과 자료구조 선택이 중요하다.


코드 주변: 'HashObject' — UObjectHash.cpp:1~

```cpp
     1  // Copyright Epic Games, Inc. All Rights Reserved.
     2  
     3  /*=============================================================================
     4  	UObjectHash.cpp: Unreal object name hashes
     5  =============================================================================*/
     6  
     7  #include "UObject/UObjectHash.h"
     8  #include "UObject/Class.h"
     9  #include "UObject/Package.h"
    10  #include "Misc/AsciiSet.h"
    11  #include "Misc/PackageName.h"
    12  #include "HAL/IConsoleManager.h"
    13  
    14  DEFINE_LOG_CATEGORY_STATIC(LogUObjectHash, Log, All);
    15  
    16  DECLARE_CYCLE_STAT( TEXT( "GetObjectsOfClass" ), STAT_Hash_GetObjectsOfClass, STATGROUP_UObjectHash );
    17  DECLARE_CYCLE_STAT( TEXT( "HashObject" ), STAT_Hash_HashObject, STATGROUP_UObjectHash );
    18  DECLARE_CYCLE_STAT( TEXT( "UnhashObject" ), STAT_Hash_UnhashObject, STATGROUP_UObjectHash );
    19  
    20  #if UE_GC_TRACK_OBJ_AVAILABLE
    21  DEFINE_STAT( STAT_Hash_NumObjects );
    22  #endif
    23  
    24  // Global UObject array instance
    25  FUObjectArray GUObjectArray;
    26  
    27  /**
    28   * This implementation will use more space than the UE3 implementation. The goal was to make UObjects smaller to save L2 cache space. 
    29   * The hash is rarely used at runtime. A more space-efficient implementation is possible.
    30   */
    31  
    32  
    33  /*
    34   * Special hash bucket to conserve memory.
    35   * Contains a pointer to head element and an optional list of items if more than one element exists in the bucket.
    36   * The item list is only allocated if needed.
    37   */
    38  struct FHashBucket
    39  {
    40  	friend struct FHashBucketIterator;
    41  
    42  	/** This always empty set is used to get an iterator if the bucket doesn't use a TSet (has only 1 element) */
    43  	static TSet<UObjectBase*> EmptyBucket;
    44  
    45  	/*
    46  	* If these are both null, this bucket is empty
    47  	* If the first one is null, but the second one is non-null, then the second one is a TSet pointer
    48  	* If the first one is not null, then it is a uobject ptr, and the second ptr is either null or a second element
    49  	*/
    50  	void *ElementsOrSetPtr[2];
    51  
    52  #if !UE_BUILD_SHIPPING
    53  	/** If true this bucket is being iterated over and no Add or Remove operations are allowed */
    54  	int32 ReadOnlyLock;
    55  
    56  	FORCEINLINE void Lock()
    57  	{
    58  		ReadOnlyLock++;
    59  	}
    60  
    61  	FORCEINLINE void Unlock()
    62  	{
    63  		ReadOnlyLock--;
    64  		check(ReadOnlyLock >= 0);
    65  	}
    66  #endif // !UE_BUILD_SHIPPING
```

해설:

해시에서 제거(unhash) 시점이 GC 파이프라인에서 앞쪽에 위치하면, 이후 시스템이 찾기를 통해 무효 객체를 다시 잡을 가능성을 줄인다.

이 계층은 ‘읽기 빈도 매우 높음’ → ‘쓰기(추가/삭제)는 상대적으로 낮음’ 패턴을 가질 수 있어, 락 전략과 자료구조 선택이 중요하다.



10. 실무 디버깅/성능 튜닝 체크리스트(소스 기반)

10.1 크래시/무효 참조(가장 흔한 원인)

UPROPERTY 누락: 토큰 스트림에 포함되지 않아 GC가 수거 → raw pointer가 댕글링.

비-UObject 싱글턴/매니저가 UObject 강참조: FGCObject로 보고하지 않으면 GC가 모름.

Delegate/Timer/Subsystem 바인딩 해제 누락: 루트에서 닿는 경로가 남아 객체가 안 죽음(메모리 유지).

PendingKill 객체 사용: 로직에서 IsPendingKill/IsValid 체크 누락.

10.2 GC 히치(프레임 드랍) 줄이기

마크가 길다: 참조 그래프(E)가 많음 → 불필요한 UObject 생성/참조 구조 단순화, 클러스터/토큰 스트림 경로 확인.

퍼지가 길다: BeginDestroy가 무겁거나, 파괴 대상이 한꺼번에 몰림 → Incremental purge/time limit 조정 고려, 파괴 분산.

클러스터 활용: 대규모 월드에서 Mark 비용 절감 가능(단, 메모리 유지 증가 가능).

10.3 소스 읽기로 성능 병목 찾는 순서

GarbageCollection.cpp: 각 단계에 통계/스코프가 있는지 확인 → 어떤 단계가 병목인지 먼저 분리.

FastReferenceCollector.h: work queue/배치 처리 구조 확인 → 병렬화가 실제로 켜져 있는지, 락 경쟁 포인트가 어디인지 파악.

Obj.cpp: BeginDestroy/FinishDestroy에서 무거운 작업(동기 IO 등)이 있는지 점검.

UObjectClusters.cpp: 클러스터 생성 기준과 실제 프로젝트 오브젝트 구성(Actor/Component 수)을 비교.
