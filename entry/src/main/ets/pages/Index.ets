import { abilityAccessCtrl, bundleManager, common, PermissionRequestResult, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { geoLocationManager } from '@kit.LocationKit';
import { map, mapCommon, MapComponent, navi } from '@kit.MapKit';
import { MOCK_ROUTE, ROUTE_CAMERA_ZOOM, ROUTE_PLAYBACK_TICK_MS } from '../data/mockRoute';
import { ROUTE_SOURCE, TRAVEL_MODE } from '../data/routeConfig';

interface MilestonePlan {
  index: number;
  label: string;
  marker?: map.Marker;
  reached: boolean;
}

interface RouteStepLike {
  points?: mapCommon.LatLng[];
  polyline?: mapCommon.LatLng[];
  path?: mapCommon.LatLng[];
}

interface RouteLike {
  points?: mapCommon.LatLng[];
  polyline?: mapCommon.LatLng[];
  path?: mapCommon.LatLng[];
  steps?: RouteStepLike[];
}

interface RouteResultLike {
  routes?: RouteLike[];
  paths?: RouteLike[];
  route?: RouteLike;
  data?: RouteLike | RouteLike[];
}

function buildCumulativeDistances(points: mapCommon.LatLng[]): number[] {
  const distances: number[] = [0];
  for (let index = 1; index < points.length; index++) {
    distances.push(distances[index - 1] + map.calculateDistance(points[index - 1], points[index]));
  }
  return distances;
}

function buildMilestones(points: mapCommon.LatLng[], cumulativeDistances: number[]): MilestonePlan[] {
  if (points.length < 4) {
    return [];
  }

  const totalDistance: number = cumulativeDistances[cumulativeDistances.length - 1];
  const targets: number[] = [totalDistance / 3, (totalDistance * 2) / 3];
  const usedIndexes: number[] = [];
  const plans: MilestonePlan[] = [];

  for (const target of targets) {
    for (let index = 1; index < points.length - 1; index++) {
      if (usedIndexes.includes(index) || cumulativeDistances[index] < target) {
        continue;
      }

      usedIndexes.push(index);
      plans.push({
        index,
        label: `${Math.round(cumulativeDistances[index] / 10) * 10} m`,
        reached: false
      });
      break;
    }
  }

  return plans;
}

@Entry
@Component
export struct Index {
  private readonly locationPermissions: Permissions[] = [
    'ohos.permission.LOCATION',
    'ohos.permission.APPROXIMATELY_LOCATION'
  ];
  private mapController?: map.MapComponentController;
  private mapEventManager?: map.MapEventManager;
  private projection?: map.Projection;
  private routePolyline?: map.MapPolyline;
  private runnerMarker?: map.Marker;
  private finishMarker?: map.Marker;
  private destinationMarker?: map.Marker;
  private playbackTimer?: number;
  private activeRouteIndex: number = 0;
  private initialized: boolean = false;
  private mapLoaded: boolean = false;
  private currentLocation?: mapCommon.LatLng;
  private selectedDestination?: mapCommon.LatLng;

  private routePoints: mapCommon.LatLng[] = [...MOCK_ROUTE];
  private cumulativeDistances: number[] = buildCumulativeDistances(this.routePoints);
  private milestonePlans: MilestonePlan[] = buildMilestones(this.routePoints, this.cumulativeDistances);

  @State mapOptions: mapCommon.MapOptions = {
    position: { target: MOCK_ROUTE[0], zoom: ROUTE_CAMERA_ZOOM },
    mapType: mapCommon.MapType.STANDARD
  };
  @State isMapReady: boolean = false;
  @State isPlaybackRunning: boolean = false;

  aboutToDisappear(): void {
    this.stopPlayback();
  }

  onPageShow(): void {
    this.mapController?.show();
  }

  onPageHide(): void {
    this.mapController?.hide();
  }

  build() {
    Column({ space: 4 }) {
      Row({ space: 8 }) {
        this.buildActionButton('Start', true, () => {
          void this.startPlayback();
        })
        this.buildActionButton(this.getSecondaryActionLabel(), false, () => {
          void this.handleSecondaryAction();
        })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)

      MapComponent({
        mapOptions: this.mapOptions,
        mapCallback: async (err: BusinessError, ctrl: map.MapComponentController) => {
          if (!err) {
            this.mapController = ctrl;
            this.mapLoaded = true;
            this.isMapReady = true;
            this.projection = ctrl.getProjection();
            if (!this.initialized) {
              this.initialized = true;
              await this.initializeMap(ctrl);
            }
          } else {
            this.isMapReady = false;
          }
        }
      })
        .width('100%')
        .height(170)
        .margin({ top: 2 })
    }
    .padding({ left: 12, right: 12, top: 8, bottom: 4 })
  }

  private getSecondaryActionLabel(): string {
    return ROUTE_SOURCE === 'api' ? 'Clean' : 'Retry';
  }

  @Builder
  private buildActionButton(label: string, primary: boolean, action: () => void): void {
    Button(label)
      .fontSize(9)
      .fontWeight(FontWeight.Medium)
      .fontColor(primary ? '#06262E' : '#E8F4F8')
      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
      .backgroundColor(primary ? '#39C6B3' : '#274154')
      .borderRadius(14)
      .opacity(this.isButtonEnabled(label) ? 0.96 : 0.45)
      .onClick(() => {
        if (!this.isButtonEnabled(label)) {
          return;
        }
        action();
      })
  }

  private isButtonEnabled(label: string): boolean {
    if (label === 'Start') {
      return this.isMapReady && !this.isPlaybackRunning && this.canStartRoute();
    }

    if (label === 'Retry' || label === 'Clean') {
      return this.isMapReady;
    }

    return false;
  }

  private canStartRoute(): boolean {
    if (ROUTE_SOURCE === 'mock') {
      return true;
    }

    return this.currentLocation !== undefined && this.selectedDestination !== undefined;
  }

  private async initializeMap(ctrl: map.MapComponentController): Promise<void> {
    this.mapEventManager = ctrl.getEventManager();
    await this.enableMyLocationFeatures();
    ctrl.setLogoAlignment(mapCommon.LogoAlignment.BOTTOM_START);
    ctrl.setLogoPadding({
      left: 90,
      bottom: 12
    });

    this.finishMarker = await ctrl.addMarker({
      position: this.routePoints[this.routePoints.length - 1],
      title: 'Finish',
      clickable: true,
      anchorU: 0.5,
      anchorV: 1,
      alpha: 1
    });

    this.mapEventManager.on('mapClick', async (position: mapCommon.LatLng) => {
      await this.handleMapTap(position);
    });

    this.mapEventManager.on('markerClick', (marker: map.Marker) => {
      this.handleMarkerTap(marker);
    });

    this.currentLocation = await this.readCurrentLocation();
    if (this.currentLocation && ROUTE_SOURCE === 'api') {
      this.centerOn(this.currentLocation);
      return;
    }

    this.centerOn(this.routePoints[0]);
  }

  private async enableMyLocationFeatures(): Promise<void> {
    const granted: boolean = await this.hasLocationPermission();
    if (!granted) {
      this.mapController?.setMyLocationControlsEnabled(true);
      await this.requestLocationPermission();
      return;
    }

    this.mapController?.setMyLocationEnabled(true);
    this.mapController?.setMyLocationControlsEnabled(true);
  }

  private async hasLocationPermission(): Promise<boolean> {
    const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    const bundleInfo: bundleManager.BundleInfo =
      await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
    const tokenId: number = bundleInfo.appInfo.accessTokenId;

    for (const permission of this.locationPermissions) {
      const grantStatus: abilityAccessCtrl.GrantStatus = await atManager.checkAccessToken(tokenId, permission);
      if (grantStatus !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
        return false;
      }
    }

    return true;
  }

  private async requestLocationPermission(): Promise<void> {
    const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const result: PermissionRequestResult = 
      await atManager.requestPermissionsFromUser(context, this.locationPermissions);

    const grantedAll: boolean = result.authResults.every((item: number) => {
      return item === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    });

    if (!grantedAll) {
      return;
    }

    this.mapController?.setMyLocationEnabled(true);
    this.mapController?.setMyLocationControlsEnabled(true);
    this.currentLocation = await this.readCurrentLocation();
  }

  private async startPlayback(): Promise<void> {
    if (!this.mapLoaded) {
      return;
    }
    const nextRoute: mapCommon.LatLng[] | undefined = await this.resolveRoutePoints();
    if (!nextRoute || nextRoute.length < 2) {
      return;
    }

    this.applyRoutePoints(nextRoute);
    await this.resetPlaybackPresentation();
    if (this.mapController && !this.finishMarker) {
      this.finishMarker = await this.mapController.addMarker({
        position: this.routePoints[this.routePoints.length - 1],
        title: 'Finish',
        clickable: true,
        anchorU: 0.5,
        anchorV: 1,
        alpha: 1
      });
    }
    if (this.mapController && !this.runnerMarker) {
      this.runnerMarker = await this.mapController.addMarker({
        position: this.routePoints[0],
        title: 'Runner',
        clickable: true,
        anchorU: 0.5,
        anchorV: 1,
        alpha: 1
      });
    }
    this.stopPlayback();
    this.isPlaybackRunning = true;
    this.activeRouteIndex = 0;
    this.playbackTimer = setInterval(() => {
      void this.advancePlayback();
    }, ROUTE_PLAYBACK_TICK_MS);
  }

  private async retryPlayback(): Promise<void> {
    await this.startPlayback();
  }

  private async handleSecondaryAction(): Promise<void> {
    if (ROUTE_SOURCE === 'api') {
      await this.cleanApiRouteState();
      return;
    }

    await this.retryPlayback();
  }

  private stopPlayback(): void {
    if (this.playbackTimer !== undefined) {
      clearInterval(this.playbackTimer);
      this.playbackTimer = undefined;
    }
    this.isPlaybackRunning = false;
  }

  private async advancePlayback(): Promise<void> {
    if (!this.mapController) {
      return;
    }

    const nextIndex: number = this.activeRouteIndex + 1;
    if (nextIndex >= this.routePoints.length) {
      this.stopPlayback();
      return;
    }

    this.activeRouteIndex = nextIndex;
    const visitedPoints: mapCommon.LatLng[] = this.routePoints.slice(0, nextIndex + 1);

    if (!this.routePolyline) {
      this.routePolyline = await this.mapController.addPolyline({
        points: visitedPoints,
        width: 10,
        color: 0xFF0A84FF
      });
    } else {
      this.routePolyline.setPoints(visitedPoints);
    }

    this.runnerMarker?.setPosition(this.routePoints[nextIndex]);
    this.centerOn(this.routePoints[nextIndex]);
    await this.revealMilestones(nextIndex);
  }

  private async resetPlaybackPresentation(): Promise<void> {
    this.stopPlayback();
    this.activeRouteIndex = 0;
    this.routePolyline?.remove();
    this.routePolyline = undefined;
    this.runnerMarker?.remove();
    this.runnerMarker = undefined;

    for (const plan of this.milestonePlans) {
      plan.marker?.remove();
      plan.marker = undefined;
      plan.reached = false;
    }

    this.centerOn(this.routePoints[0]);
  }

  private async cleanApiRouteState(): Promise<void> {
    await this.resetPlaybackPresentation();
    this.finishMarker?.remove();
    this.finishMarker = undefined;
    this.destinationMarker?.remove();
    this.destinationMarker = undefined;
    this.selectedDestination = undefined;

    if (this.currentLocation) {
      this.centerOn(this.currentLocation);
    }
  }

  private async revealMilestones(routeIndex: number): Promise<void> {
    if (!this.mapController) {
      return;
    }

    for (const plan of this.milestonePlans) {
      if (plan.reached || routeIndex < plan.index) {
        continue;
      }

      plan.reached = true;
      plan.marker = await this.mapController.addMarker({
        position: this.routePoints[plan.index],
        title: plan.label,
        clickable: true,
        anchorU: 0.5,
        anchorV: 1,
        alpha: 1
      });
    }
  }

  private centerOn(point: mapCommon.LatLng): void {
    this.mapController?.moveCamera(map.newLatLng(point, ROUTE_CAMERA_ZOOM));
  }

  private async handleMapTap(position: mapCommon.LatLng): Promise<void> {
    if (!this.mapController || !this.projection) {
      return;
    }

    const screenPoint: mapCommon.MapPoint = this.projection.toScreenLocation(position);
    const projectedPosition: mapCommon.LatLng = this.projection.fromScreenLocation(screenPoint);

    if (ROUTE_SOURCE === 'api') {
      await this.cleanApiRouteState();
    }

    this.selectedDestination = projectedPosition;

    if (!this.destinationMarker) {
      this.destinationMarker = await this.mapController.addMarker({
        position: projectedPosition,
        title: 'Destination',
        clickable: true,
        anchorU: 0.5,
        anchorV: 1,
        alpha: 1
      });
      return;
    }

    this.destinationMarker.setPosition(projectedPosition);
    this.destinationMarker.setVisible(true);
  }

  private handleMarkerTap(marker: map.Marker): void {
    if (marker === this.destinationMarker) {
      return;
    }

    for (const plan of this.milestonePlans) {
      if (marker === plan.marker) {
        return;
      }
    }
  }

  private async readCurrentLocation(): Promise<mapCommon.LatLng | undefined> {
    try {
      const location = await geoLocationManager.getCurrentLocation();
      return {
        latitude: location.latitude,
        longitude: location.longitude
      };
    } catch (_) {
      return undefined;
    }
  }

  private async resolveRoutePoints(): Promise<mapCommon.LatLng[] | undefined> {
    if (ROUTE_SOURCE === 'mock') {
      return [...MOCK_ROUTE];
    }

    this.currentLocation = await this.readCurrentLocation();
    if (!this.currentLocation || !this.selectedDestination) {
      return undefined;
    }

    const plannedRoute: mapCommon.LatLng[] | undefined = await this.fetchPlannedRoute(
      this.currentLocation,
      this.selectedDestination
    );

    if (plannedRoute && plannedRoute.length >= 2) {
      return plannedRoute;
    }

    return this.buildFallbackRoute(this.currentLocation, this.selectedDestination);
  }

  private async fetchPlannedRoute(
    start: mapCommon.LatLng,
    destination: mapCommon.LatLng
  ): Promise<mapCommon.LatLng[] | undefined> {
    try {
      const params: navi.RouteParams = {
        origins: [start],
        destination,
        language: 'en_US'
      };

      let result: navi.RouteResult;
      switch (TRAVEL_MODE) {
        case 'cycling':
          result = await navi.getCyclingRoutes(params);
          break;
        case 'driving':
          result = await navi.getDrivingRoutes({
            origins: [start],
            destination,
            language: 'en_US'
          });
          break;
        default:
          result = await navi.getWalkingRoutes(params);
          break;
      }

      return this.extractBestRoutePoints(result);
    } catch (_) {
      return undefined;
    }
  }

  private extractBestRoutePoints(payload: navi.RouteResult): mapCommon.LatLng[] | undefined {
    const result = payload as RouteResultLike;

    if (result.routes && result.routes.length > 0) {
      return this.extractRouteLikePoints(result.routes[0]);
    }

    if (result.paths && result.paths.length > 0) {
      return this.extractRouteLikePoints(result.paths[0]);
    }

    if (result.route) {
      return this.extractRouteLikePoints(result.route);
    }

    if (Array.isArray(result.data) && result.data.length > 0) {
      return this.extractRouteLikePoints(result.data[0]);
    }

    if (result.data && !Array.isArray(result.data)) {
      return this.extractRouteLikePoints(result.data);
    }

    return undefined;
  }

  private extractRouteLikePoints(route: RouteLike): mapCommon.LatLng[] | undefined {
    if (route.points && route.points.length > 1) {
      return route.points;
    }

    if (route.polyline && route.polyline.length > 1) {
      return route.polyline;
    }

    if (route.path && route.path.length > 1) {
      return route.path;
    }

    if (!route.steps || route.steps.length === 0) {
      return undefined;
    }

    const collected: mapCommon.LatLng[] = [];
    for (const step of route.steps) {
      const stepPoints = this.extractStepPoints(step);
      if (!stepPoints || stepPoints.length === 0) {
        continue;
      }

      for (const point of stepPoints) {
        collected.push(point);
      }
    }

    return collected.length > 1 ? collected : undefined;
  }

  private extractStepPoints(step: RouteStepLike): mapCommon.LatLng[] | undefined {
    if (step.points && step.points.length > 0) {
      return step.points;
    }

    if (step.polyline && step.polyline.length > 0) {
      return step.polyline;
    }

    if (step.path && step.path.length > 0) {
      return step.path;
    }

    return undefined;
  }

  private buildFallbackRoute(start: mapCommon.LatLng, destination: mapCommon.LatLng): mapCommon.LatLng[] {
    const points: mapCommon.LatLng[] = [];
    const segments = 8;

    for (let index = 0; index <= segments; index++) {
      const ratio = index / segments;
      points.push({
        latitude: start.latitude + (destination.latitude - start.latitude) * ratio,
        longitude: start.longitude + (destination.longitude - start.longitude) * ratio
      });
    }

    return points;
  }

  private applyRoutePoints(points: mapCommon.LatLng[]): void {
    this.routePoints = points;
    this.cumulativeDistances = buildCumulativeDistances(points);
    this.milestonePlans = buildMilestones(points, this.cumulativeDistances);
    this.finishMarker?.remove();
    this.finishMarker = undefined;
  }

}
