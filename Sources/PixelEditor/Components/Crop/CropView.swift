//
// Copyright (c) 2021 Muukii <muukii.app@gmail.com>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import CoreImage

import UIKit
import Verge

#if !COCOAPODS
import PixelEngine
#endif

/**
 A view that previews how crops the image.

 The cropping adjustument is avaibleble from 2 ways:
 - Scrolling image
 - Panning guide
 */
public final class CropView: UIView, UIScrollViewDelegate {
  public struct State: Equatable {
    public enum AdjustmentKind: Equatable {
      case scrollView
      case guide
    }

    enum ModifiedSource: Equatable {
      case fromState
      case fromScrollView
      case fromGuide
    }

    public fileprivate(set) var proposedCrop: EditingCrop?

    public fileprivate(set) var adjustmentKind: AdjustmentKind?

    public fileprivate(set) var frame: CGRect = .zero
    
    fileprivate var hasLoaded = false
    fileprivate var isGuideInteractionEnabled: Bool = true
    fileprivate var layoutVersion: UInt64 = 0
  }

  /**
   A view that covers the area out of cropping extent.
   */
  public private(set) weak var cropOutsideOverlay: UIView?

  public let store: UIStateStore<State, Never> = .init(initialState: .init(), logger: nil)

  /**
   A Boolean value that indicates whether the guide is interactive.
   If false, cropping adjustment is available only way from scrolling image-view.
   */
  public var isGuideInteractionEnabled: Bool {
    get {
      store.state.isGuideInteractionEnabled
    }
    set {
      store.commit {
        $0.isGuideInteractionEnabled = newValue
      }
    }
  }
  
  public let editingStack: EditingStack

  /**
   An image view that displayed in the scroll view.
   */
  #if true
  private let imageView = _ImageView()
  #else
  private let imageView: UIView & HardwareImageViewType = {
    return MetalImageView()
  }()
  #endif
  private let scrollView = _CropScrollView()
  private let scrollBackdropView = UIView()
  private var hasSetupScrollViewCompleted = false

  /**
   a guide view that displayed on guide container view.
   */
  private lazy var guideView = _InteractiveCropGuideView(
    containerView: self,
    imageView: self.imageView,
    insetOfGuideFlexibility: contentInset
  )

  private var subscriptions = Set<VergeAnyCancellable>()

  /// A throttling timer to apply guide changed event.
  ///
  /// This's waiting for Combine availability in minimum iOS Version.
  private let debounce = Debounce(interval: 0.8)

  private let contentInset: UIEdgeInsets
  
  private var loadingOverlayFactory: (() -> UIView)?
  private weak var currentLoadingOverlay: UIView?
  
  private var isBinding = false
  
  var isAutoApplyEditingStackEnabled = false
  
  // MARK: - Initializers

  /**
   Creates an instance for using as standalone.

   This initializer offers us to get cropping function without detailed setup.
   To get a result image, call `renderImage()`.
   */
  public convenience init(
    image: UIImage,
    contentInset: UIEdgeInsets = .init(top: 20, left: 20, bottom: 20, right: 20)
  ) {
    self.init(
      editingStack: .init(
        imageProvider: .init(image: image),
        previewMaxPixelSize: UIScreen.main.bounds.height * UIScreen.main.scale
      ),
      contentInset: contentInset
    )
  }

  public init(
    editingStack: EditingStack,
    contentInset: UIEdgeInsets = .init(top: 20, left: 20, bottom: 20, right: 20)
  ) {
    _pixeleditor_ensureMainThread()

    self.editingStack = editingStack
    self.contentInset = contentInset

    super.init(frame: .zero)

    clipsToBounds = false

    addSubview(scrollBackdropView)
    addSubview(scrollView)
    addSubview(guideView)

    imageView.isUserInteractionEnabled = true
    scrollView.addSubview(imageView)
    scrollView.delegate = self

    guideView.didChange = { [weak self] in
      guard let self = self else { return }
      self.didChangeGuideViewWithDelay()
    }

    guideView.willChange = { [weak self] in
      guard let self = self else { return }
      self.willChangeGuideView()
    }

    #if false
    store.sinkState { state in
      EditorLog.debug(state.primitive)
    }
    .store(in: &subscriptions)
    #endif
    
    editingStack.sinkState { [weak self] state in
      
      guard let self = self else { return }
            
      state.ifChanged(\.currentEdit.crop) { cropRect in
        
        /**
         To avoid running pending layout operations from User Initiated actions.
         */
        if cropRect != self.store.state.proposedCrop {
          self.setCrop(cropRect)
        }
      }

    }
    .store(in: &subscriptions)
  
    defaultAppearance: do {
      setCropInsideOverlay(CropView.CropInsideOverlayRuleOfThirdsView())
      setCropOutsideOverlay(CropView.CropOutsideOverlayBlurredView())
      setLoadingOverlay(factory: {
        LoadingBlurryOverlayView(effect: UIBlurEffect(style: .dark), activityIndicatorStyle: .whiteLarge)
      })
    }
  }

  @available(*, unavailable)
  public required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Functions
  
  public override func willMove(toSuperview newSuperview: UIView?) {
    super.willMove(toSuperview: newSuperview)
    
    if isBinding == false {
      isBinding = true
      
      binding: do {
        store.sinkState(queue: .mainIsolated()) { [weak self] state in
          
          guard let self = self else { return }
          
          state.ifChanged({
            (
              $0.frame,
              $0.layoutVersion
            )
          }, .init(==)) { (frame, _) in
       
            let crop = state.proposedCrop
            
            guard frame != .zero else { return }
            
            if let crop = crop {
              
              setupScrollViewOnce: do {
                if self.hasSetupScrollViewCompleted == false {
                  self.hasSetupScrollViewCompleted = true
                  
                  let scrollView = self.scrollView
                  
                  self.imageView.bounds = .init(origin: .zero, size: crop.scrollViewContentSize())
                  
                  let (min, max) = crop.calculateZoomScale(scrollViewBounds: scrollView.bounds)
                  
                  scrollView.minimumZoomScale = min
                  scrollView.maximumZoomScale = max
                  
                  // Do we need this? it seems ImageView's bounds changes contentSize automatically. not sure.
                  UIView.performWithoutAnimation {
                    let currentZoomScale = scrollView.zoomScale
                    let contentSize = crop.scrollViewContentSize()
                    if scrollView.contentSize != contentSize {
                      scrollView.contentInset = .zero
                      scrollView.zoomScale = 1
                      scrollView.contentSize = contentSize
                      scrollView.zoomScale = currentZoomScale
                    }
                  }
                }
              }
              
              self.updateScrollContainerView(
                by: crop,
                animated: state.hasLoaded,
                animatesRotation: state.hasChanges(\.proposedCrop?.rotation)
              )
            } else {
              // TODO:
            }
          }
          
          if self.isAutoApplyEditingStackEnabled {
            state.ifChanged(\.proposedCrop) { crop in
              guard let crop = crop else { return }
              self.editingStack.crop(crop)
            }
          }
          
          state.ifChanged(\.isGuideInteractionEnabled) { value in
            self.guideView.isUserInteractionEnabled = value
          }
        }
        .store(in: &subscriptions)
        
        editingStack.sinkState { [weak self] state in
          
          guard let self = self else { return }
          
          state.ifChanged(\.isLoading) { isLoading in
            self.updateLoadingOverlay(displays: isLoading)
          }
          
          state.ifChanged(\.placeholderImage, \.editingSourceImage) { previewImage, image in
            
            if let previewImage = previewImage {
              self.setImage(previewImage)
            }
            
            if let image = image {
              self.setImage(image)
            }
          
          }
        }
        .store(in: &subscriptions)
      }
      
    }
    
  }
  
  private func updateLoadingOverlay(displays: Bool) {
    
    if displays, let factory = self.loadingOverlayFactory {
      
      let loadingOverlay = factory()
      self.currentLoadingOverlay = loadingOverlay
      self.addSubview(loadingOverlay)
      AutoLayoutTools.setEdge(loadingOverlay, self.guideView)
      
      loadingOverlay.alpha = 0
      UIViewPropertyAnimator(duration: 0.6, dampingRatio: 1) {
        loadingOverlay.alpha = 1
      }
      .startAnimation()
      
    } else {
      
      if let view = currentLoadingOverlay {
        UIViewPropertyAnimator(duration: 0.6, dampingRatio: 1) {
          view.alpha = 0
        }&>.do {
          $0.addCompletion { _ in
            view.removeFromSuperview()
          }
          $0.startAnimation()
        }
      }
                 
    }
    
  }
    
  /**
   Renders an image according to the editing.

   - Attension: This operation can be run background-thread.
   */
  public func renderImage() -> UIImage {
    applyEditingStack()
    return editingStack.makeRenderer().render()
  }
  
  /**
   Applies the current state to the EditingStack.
   */
  public func applyEditingStack() {
    
    guard let crop = store.state.proposedCrop else {
      return
    }
    editingStack.crop(crop)
  }

  public func resetCrop() {
    _pixeleditor_ensureMainThread()

    store.commit {
      $0.proposedCrop = $0.proposedCrop?.makeInitial()
      $0.layoutVersion += 1
    }

    guideView.setLockedAspectRatio(nil)
  }

  public func setRotation(_ rotation: EditingCrop.Rotation) {
    _pixeleditor_ensureMainThread()

    store.commit {
      $0.proposedCrop?.rotation = rotation
      $0.layoutVersion += 1
    }
  }

  public func setCrop(_ crop: EditingCrop) {
    _pixeleditor_ensureMainThread()
    
    store.commit {
      $0.proposedCrop = crop
      $0.layoutVersion += 1
    }
  }

  public func setCroppingAspectRatio(_ ratio: PixelAspectRatio) {
    _pixeleditor_ensureMainThread()

    store.commit {
      assert($0.proposedCrop != nil)
      $0.proposedCrop?.updateCropExtent(by: ratio)
      $0.proposedCrop?.preferredAspectRatio = ratio
      $0.layoutVersion += 1
    }
  }

  /**
   Displays a view as an overlay.
   e.g. grid view

   - Parameters:
   - view: In case of no needs to display overlay, pass nil.
   */
  public func setCropInsideOverlay(_ view: CropInsideOverlayBase?) {
    _pixeleditor_ensureMainThread()

    guideView.setCropInsideOverlay(view)
  }

  /**
   Displays an overlay that covers the area out of cropping extent.
   Given view's frame would be adjusted automatically.

   - Attention: view's userIntereactionEnabled turns off
   - Parameters:
   - view: In case of no needs to display overlay, pass nil.
   */
  public func setCropOutsideOverlay(_ view: CropOutsideOverlayBase?) {
    _pixeleditor_ensureMainThread()

    cropOutsideOverlay?.removeFromSuperview()

    guard let view = view else {
      // just removing
      return
    }

    cropOutsideOverlay = view
    view.isUserInteractionEnabled = false

    // TODO: Unstable operation.
    insertSubview(view, aboveSubview: scrollView)

    guideView.setCropOutsideOverlay(view)

    setNeedsLayout()
    layoutIfNeeded()
  }
  
  public func setLoadingOverlay(factory: (() -> UIView)?) {
    _pixeleditor_ensureMainThread()
    loadingOverlayFactory = factory
  }
    
}

// MARK: Internal

extension CropView {
  private func setImage(_ ciImage: CIImage) {
    imageView.display(image: ciImage)
  }
  
  override public func layoutSubviews() {
    super.layoutSubviews()
    
    if let outOfBoundsOverlay = cropOutsideOverlay {
      outOfBoundsOverlay.frame.size = .init(width: 1000, height: 1000)
      outOfBoundsOverlay.center = center
    }
    
    store.commit {
      if $0.frame != frame {
        $0.frame = frame
      }
    }
       
  }

  override public func didMoveToSuperview() {
    super.didMoveToSuperview()

    DispatchQueue.main.async { [self] in
      store.commit {
        $0.hasLoaded = superview != nil
      }
    }
  }

  private func updateScrollContainerView(
    by crop: EditingCrop,
    animated: Bool,
    animatesRotation: Bool
  ) {
    func perform() {
      frame: do {
        let bounds = self.bounds.inset(by: contentInset)

        let size: CGSize
        let aspectRatio = PixelAspectRatio(crop.cropExtent.size)
        switch crop.rotation {
        case .angle_0:
          size = aspectRatio.sizeThatFits(in: bounds.size)
          guideView.setLockedAspectRatio(crop.preferredAspectRatio)
        case .angle_90:
          size = aspectRatio.swapped().sizeThatFits(in: bounds.size)
          guideView.setLockedAspectRatio(crop.preferredAspectRatio?.swapped())
        case .angle_180:
          size = aspectRatio.sizeThatFits(in: bounds.size)
          guideView.setLockedAspectRatio(crop.preferredAspectRatio)
        case .angle_270:
          size = aspectRatio.swapped().sizeThatFits(in: bounds.size)
          guideView.setLockedAspectRatio(crop.preferredAspectRatio?.swapped())
        }

        scrollView.transform = crop.rotation.transform
        
        scrollView.frame = .init(
          origin: .init(
            x: contentInset.left + ((bounds.width - size.width) / 2) /* centering offset */,
            y: contentInset.top + ((bounds.height - size.height) / 2) /* centering offset */
          ),
          size: size
        )
        
        scrollBackdropView.frame = scrollView.frame
      }

      applyLayoutDescendants: do {
        guideView.frame = scrollView.frame
      }

      zoom: do {
        scrollView.zoom(to: crop.cropExtent, animated: false)
        // WORKAROUND:
        // Fixes `zoom to rect` does not apply the correct state when restoring the state from first-time displaying view.
        scrollView.zoom(to: crop.cropExtent, animated: false)
      }
    }
        
    if animated {
      layoutIfNeeded()

      if animatesRotation {
        UIViewPropertyAnimator(duration: 0.6, dampingRatio: 1) {
          perform()
        }&>.do {
          $0.isUserInteractionEnabled = false
          $0.startAnimation()
        }

        UIViewPropertyAnimator(duration: 0.12, dampingRatio: 1) {
          self.guideView.alpha = 0
        }&>.do {
          $0.isUserInteractionEnabled = false
          $0.addCompletion { _ in
            UIViewPropertyAnimator(duration: 0.5, dampingRatio: 1) {
              self.guideView.alpha = 1
            }
            .startAnimation(afterDelay: 0.8)
          }
          $0.startAnimation()
        }

      } else {
        UIViewPropertyAnimator(duration: 0.6, dampingRatio: 1) { [self] in
          perform()
          layoutIfNeeded()
        }&>.do {
          $0.startAnimation()
        }
      }

    } else {
      UIView.performWithoutAnimation {
        layoutIfNeeded()
        perform()
      }
    }
  }

  @inline(__always)
  private func willChangeGuideView() {
    debounce.on { /* for debounce */ }
  }

  @inline(__always)
  private func didChangeGuideViewWithDelay() {
    
    // TODO: Apply only value immediately, and updates UI later.
    
    let visibleRect = guideView.convert(guideView.bounds, to: imageView)
    
    updateContentInset: do {
      let rect = self.guideView.convert(self.guideView.bounds, to: scrollBackdropView)
      let bounds = scrollBackdropView.bounds
      let insets = UIEdgeInsets.init(
        top: rect.minY,
        left: rect.minX,
        bottom: bounds.maxY - rect.maxY,
        right: bounds.maxX - rect.maxX
      )
      
      scrollView.contentInset = insets
    }
    
    store.commit {
      if var crop = $0.proposedCrop {
        // TODO: Might cause wrong cropping if set the invalid size or origin. For example, setting width:0, height: 0 by too zoomed in.
        crop.cropExtent = visibleRect
        $0.proposedCrop = crop
      } else {
        assertionFailure()
      }
    }
        
    debounce.on { [weak self] in

      guard let self = self else { return }

      self.store.commit {
        $0.layoutVersion += 1
      }
    }
  }

  @inline(__always)
  private func didChangeScrollView() {
    store.commit {
      let rect = guideView.convert(guideView.bounds, to: imageView)
      
      if var crop = $0.proposedCrop {
        // TODO: Might cause wrong cropping if set the invalid size or origin. For example, setting width:0, height: 0 by too zoomed in.
        crop.cropExtent = rect
        $0.proposedCrop = crop
      } else {
        assertionFailure()
      }
    }
  }

  // MARK: UIScrollViewDelegate

  public func viewForZooming(in scrollView: UIScrollView) -> UIView? {
    return imageView
  }

  public func scrollViewDidZoom(_ scrollView: UIScrollView) {
    func adjustFrameToCenterOnZooming() {
      var frameToCenter = imageView.frame

      // center horizontally
      if frameToCenter.size.width < scrollView.bounds.width {
        frameToCenter.origin.x = (scrollView.bounds.width - frameToCenter.size.width) / 2
      } else {
        frameToCenter.origin.x = 0
      }

      // center vertically
      if frameToCenter.size.height < scrollView.bounds.height {
        frameToCenter.origin.y = (scrollView.bounds.height - frameToCenter.size.height) / 2
      } else {
        frameToCenter.origin.y = 0
      }

      imageView.frame = frameToCenter
    }

    adjustFrameToCenterOnZooming()
    
    debounce.on { [weak self] in
      
      guard let self = self else { return }
      
      self.store.commit {
        $0.layoutVersion += 1
      }
    }
  }
  
  public func scrollViewDidScroll(_ scrollView: UIScrollView) {
    
    debounce.on { [weak self] in
      
      guard let self = self else { return }
      
      self.store.commit {
        $0.layoutVersion += 1
      }
    }
  }

  public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    guideView.willBeginScrollViewAdjustment()
  }

  public func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
    guideView.willBeginScrollViewAdjustment()
  }

  public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
    if !decelerate {
      didChangeScrollView()
      guideView.didEndScrollViewAdjustment()
    }
  }

  public func scrollViewDidEndZooming(
    _ scrollView: UIScrollView,
    with view: UIView?,
    atScale scale: CGFloat
  ) {
    didChangeScrollView()
    guideView.didEndScrollViewAdjustment()
  }

  public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    didChangeScrollView()
    guideView.didEndScrollViewAdjustment()
  }
}

extension EditingCrop {
  fileprivate func scrollViewContentSize() -> CGSize {
    imageSize
  }

  fileprivate func calculateZoomScale(scrollViewBounds: CGRect) -> (min: CGFloat, max: CGFloat) {
    let minXScale = scrollViewBounds.width / imageSize.width
    let minYScale = scrollViewBounds.height / imageSize.height

    /**
     max meaning scale aspect fill
     */
    let minScale = max(minXScale, minYScale)

    return (min: minScale, max: .greatestFiniteMagnitude)
  }
}
